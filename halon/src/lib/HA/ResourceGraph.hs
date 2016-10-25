-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- The knowledge of the cluster is represented as a graph of relationships
-- between resources. A resource is uniquely identified through its 'Eq'
-- instance: @x@ and @y@ are considered the same resource if @x == y@.
-- Resources may be related by any number of relations. In this sense, the
-- resource graph is, strictly speaking, a multigraph.
--
-- A pair of resources in a relation is called a relationship, or edge.
-- Relations type edges. Relations must always be singleton types, meaning
-- that there is only ever one relation in a relation type, so that the two
-- concepts can be identified.
--
-- Hence, the type of a relation completely determines the relation. An edge
-- is uniquely characterized by the resources it connects and the relation it
-- is an element of.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

module HA.ResourceGraph
    ( -- * Types
      Resource(..)
    , Relation(..)
    , Graph
    , Edge(..)
    , Dict(..)
    , Res(..)
    , Rel(..)
    , Cardinality(..)
    -- , Quantify(..)
    -- * Operations
    , newResource
    , insertEdge
    , deleteEdge
    , connect
    , disconnect
    , disconnectAllFrom
    , disconnectAllTo
    , removeResource
    , mergeResources
    , sync
    , emptyGraph
    , getGraph
    , garbageCollect
    , garbageCollectRoot
    -- * Queries
    , null
    , memberResource
    , memberEdge
    , edgesFromSrc
    , edgesToDst
    , connectedFrom
    , connectedTo
    , anyConnectedFrom
    , anyConnectedTo
    , isConnected
    , __remoteTable
    , getGraphResources
    , getResourcesOfType
    , asUnbounded
    -- * GC control
    , addRootNode
    , getGCThreshold
    , getRootNodes
    , getSinceGC
    , isRootNode
    , modifyGCThreshold
    , modifySinceGC
    , removeRootNode
    , setGCThreshold
    , setSinceGC
    ) where

import HA.Logger
import HA.Multimap
  ( Key
  , Value
  , StoreUpdate(..)
  , StoreChan
  , updateStore
  , MetaInfo(..)
  , getStoreValue
  , defaultMetaInfo
  )
import HA.Multimap.Implementation

import Control.Distributed.Process ( Process )
import Control.Distributed.Process.Internal.Types
    ( remoteTable, processNode )
import Control.Distributed.Static
  ( RemoteTable
  , Static
  , unstatic
  , staticApply
  )
import Control.Distributed.Process.Closure
import Data.Constraint ( Dict(..) )

import Prelude hiding (null)
import Control.Arrow ( (***), (>>>), second )
import Control.Monad ( liftM3 )
import Control.Monad.Reader ( ask )
import Data.Binary ( Binary(..), encode )
import Data.Binary.Get ( runGetOrFail )
import qualified Data.ByteString as Strict ( concat )
import Data.ByteString ( ByteString )
import Data.ByteString.Lazy as Lazy ( fromChunks, toChunks, append )
import qualified Data.ByteString.Lazy as Lazy ( ByteString )
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as M
import Data.HashSet (HashSet)
import qualified Data.HashSet as S
import Data.Hashable
import Data.List (foldl', delete)
import Data.Maybe
import Data.Proxy
import Data.SafeCopy
import Data.Serialize.Get (runGetLazy)
import Data.Serialize.Put (runPutLazy)
import Data.Singletons.TH
import Data.Typeable
import Data.Word (Word8)
import GHC.Generics (Generic)

rgTrace :: String -> Process ()
rgTrace = mkHalonTracer "RG"

-- | A type can be declared as modeling a resource by making it an instance of
-- this class.
class (Eq a, Hashable a, Typeable a, SafeCopy a, Show a) => Resource a where
  resourceDict :: Static (Dict (Resource a))

deriving instance Typeable Resource

-- The cardinalities of relations allow for at most one element
-- or any amount of elements.
$(singletons [d|
  data Cardinality = AtMostOne | Unbounded
    deriving Show
  |])

-- | Determines how many values of a type can be yielded according to
-- the cardinality.
type family Quantify (c :: Cardinality) :: (* -> *) where
  Quantify 'AtMostOne = Maybe
  Quantify 'Unbounded = []

-- | A relation on resources specifies what relationships can exist between
-- any two given types of resources. Two resources of type @a@, @b@, cannot be
-- related through @r@ if an @Relation r a b@ instance does not exist.
class ( Hashable r, Typeable r, SafeCopy r, Resource a, Resource b, Show r
      , SingI (CardinalityFrom r a b), SingI (CardinalityTo r a b))
      => Relation r a b where
  type CardinalityFrom r a b :: Cardinality
  type CardinalityTo r a b :: Cardinality
  relationDict :: Static (Dict (Relation r a b))

deriving instance Typeable Relation

-- | An internal wrapper for resources to have one universal type of resources.
data Res = forall a. Resource a => Res !a

-- | Short for "relationship". A relationship in an element of a relation.
-- A relationship is synomymous to an edge. Relationships are not type indexed
-- and are internal to this module. Edges are external representations of
-- a relationship.
data Rel = forall r a b. Relation r a b => InRel !r a b
         | forall r a b. Relation r a b => OutRel !r a b

instance Hashable Res where
    hashWithSalt s (Res x) = s `hashWithSalt` (typeOf x, x)

instance Hashable Rel where
    hashWithSalt s (InRel r a b) =
        s `hashWithSalt` (0 :: Int) `hashWithSalt` (typeOf r, r)
          `hashWithSalt` (typeOf a, a) `hashWithSalt` (typeOf b, b)
    hashWithSalt s (OutRel r a b) =
        s `hashWithSalt` (1 :: Int) `hashWithSalt` (typeOf r, r)
          `hashWithSalt` (typeOf a, a) `hashWithSalt` (typeOf b, b)

instance Eq Res where
    Res x == Res y = maybe False (x==) $ cast y

instance Eq Rel where
  a == b = case (a,b) of
      (InRel r1 x1 y1, InRel r2 x2 y2) -> comp (r1, x1, y1) (r2, x2, y2)
      (OutRel r1 x1 y1, OutRel r2 x2 y2) -> comp (r1, x1, y1) (r2, x2, y2)
      _ -> False
    where
      comp (_ :: r, x1, y1) (r2, x2, y2)
          | Just _ <- cast r2 :: Maybe r,
            Just x2' <- cast x2,
            Just y2' <- cast y2 =
            -- Don't need to compare r1, r2 for equality because they are
            -- assumed to be witnesses of singleton types, so if the type cast
            -- above works then they must be equal.
            x1 == x2' && y1 == y2'
          | otherwise = False

instance Show Res where
  show (Res x) = "Res (" ++ show x ++ ")"

-- XXX Specialized existential datatypes required because 'remotable' does not
-- yet support higher kinded type variables.

data SomeResourceDict = forall a. SomeResourceDict (Dict (Resource a))
    deriving Typeable
data SomeRelationDict = forall r a b. SomeRelationDict (Dict (Relation r a b))
    deriving Typeable

-- | Information about graph garbage collection. This is an internal
-- structure which is hidden away from the user in the graph itself,
-- allowing it to persist through multimap updates.
data GraphGCInfo = GraphGCInfo
  { -- | Number of times we disconnected resources in the graph. Used
    -- to determine whether we should run GC or not. Note that this is
    -- only a heuristic, not an /accurate/ number of resources we have
    -- actually disconnected. Disconnecting the same resource multiple
    -- times will have no effect but will increase 'grSinceGC'.
    grSinceGC :: Int
    -- | Amount of disconnects after which the GC should be ran. There
    -- is no guarantee that GC will run after precisely after this
    -- many. If the value is not a positive integer, the automatic GC
    -- won't be ran at all. Defaults to @100@.
  , grGCThreshold :: Int
    -- | Set of nodes that we consider as being roots
  , grRootNodes :: [Res]
  } deriving (Eq, Typeable, Generic, Show)

-- XXX Wrapper functions because 'remotable' doesn't like constructors names.

someResourceDict :: Dict (Resource a) -> SomeResourceDict
someResourceDict = SomeResourceDict

someRelationDict :: Dict (Relation r a b) -> SomeRelationDict
someRelationDict = SomeRelationDict

remotable ['someResourceDict, 'someRelationDict]

-- | Predicate to select 'in' edges.
isIn :: Rel -> Bool
isIn (InRel _ _ _) = True
isIn (OutRel _ _ _) = False

-- | Predicate to select 'out' edges.
isOut :: Rel -> Bool
isOut = not . isIn

-- | Invert a relation
inverse :: Rel -> Rel
inverse (OutRel a b c) = InRel a b c
inverse (InRel a b c) = OutRel a b c

class AsUnbounded x c where asUnbounded :: x -> [c]
instance AsUnbounded [c] c where asUnbounded = id
instance AsUnbounded (Maybe c) c where asUnbounded = maybeToList

-- | A change log for graph updates.
--
-- Has a multimap with insertions of nodes and edges, a multimap with removals
-- of edges and a set of removals of nodes.
--
-- The structure must preserve the following invariants:
-- * Edges in the insertion multimap are not present in the removal multimap.
-- * Nodes in the insertion multimap are not present in the removal set.
-- * Nodes in the removal multimap are not present in removal set.
data ChangeLog = ChangeLog !Multimap !Multimap !(HashSet Key) (Maybe MetaInfo)
  deriving Typeable

-- | Gets a list of updates and produces a possibly shorter equivalent list.
--
-- The updates are compressed by merging the multiple updates that could be
-- found for a given key.
updateChangeLog :: StoreUpdate -> ChangeLog -> ChangeLog
updateChangeLog x (ChangeLog is dvs dks mi) = case x of
    InsertMany kvs ->
       ChangeLog (insertMany kvs is) (deleteValues kvs dvs)
                 (foldr S.delete dks $ map fst kvs) mi
    DeleteValues kvs ->
      let kvs' = filter (not . flip S.member dks . fst) kvs
      in ChangeLog (deleteValues kvs is) (insertMany kvs' dvs) dks mi
    DeleteKeys ks ->
      ChangeLog (deleteKeys ks is) (deleteKeys ks dvs) (foldr S.insert dks ks) mi
    SetMetaInfo mi' -> ChangeLog is dvs dks (Just mi')

-- | Gets the list of updates from the changelog.
fromChangeLog :: ChangeLog -> [StoreUpdate]
fromChangeLog (ChangeLog is dvs dks mi) =
    [ InsertMany   $ toList is
    , DeleteValues $ toList dvs
    , DeleteKeys   $ S.toList dks
    ] ++ maybeToList (SetMetaInfo <$> mi)

-- | An empty changelog
emptyChangeLog :: ChangeLog
emptyChangeLog = ChangeLog empty empty S.empty Nothing

-- | The graph
data Graph = Graph
  { -- | Channel used to communicate with the multimap which replicates the
    -- graph.
    grMMChan :: StoreChan
    -- | Changes in the graph with respect to the version stored in the multimap.
  , grChangeLog :: !ChangeLog
    -- | The graph.
  , grGraph :: HashMap Res (HashSet Rel)
    -- | Metadata about the graph GC
  , grGraphGCInfo :: GraphGCInfo
  } deriving (Typeable)

-- | Edges between resources. Edge types are called relations. An edge is an
-- element of some relation. The order of the fields matches that of
-- subject-verb-object triples in RDF.
data Edge a r b =
    Edge { edgeSrc      :: !a
         , edgeRelation :: !r
         , edgeDst      :: !b }
  deriving Eq

-- | Returns @True@ iff the graph is empty, with the exception of
-- 'GraphGCInfo' resources which are filtered out before making the
-- check.
null :: Graph -> Bool
null = M.null . grGraph

-- | Tests whether a given resource is a vertex in a given graph.
memberResource :: Resource a => a -> Graph -> Bool
memberResource a g = M.member (Res a) $ grGraph g

-- | Test whether two resources are connected through the given relation.
memberEdge :: forall a r b. Relation r a b => Edge a r b -> Graph -> Bool
memberEdge e g =
    (outFromEdge e) `S.member` maybe S.empty (S.filter isOut) (M.lookup (Res (edgeSrc e)) (grGraph g))

outFromEdge :: Relation r a b => Edge a r b -> Rel
outFromEdge Edge{..} = OutRel edgeRelation edgeSrc edgeDst

inFromEdge :: Relation r a b => Edge a r b -> Rel
inFromEdge Edge{..} = InRel edgeRelation edgeSrc edgeDst

-- | Register a new resource. A resource is meant to be immutable: it does not
-- change and lives forever.
newResource :: Resource a => a -> Graph -> Graph
newResource x g =
    g { grChangeLog = updateChangeLog (InsertMany [ (encodeRes (Res x),[]) ])
                                      (grChangeLog g)
      , grGraph = M.insertWith combineRes (Res x) S.empty $ grGraph g
      }
  where
    combineRes _ es = es

-- | Connect source and destination resources through a directed edge.
insertEdge :: Relation r a b => Edge a r b -> Graph -> Graph
insertEdge Edge{..} = connect edgeSrc edgeRelation edgeDst

-- | Delete an edge from the graph.
deleteEdge :: Relation r a b => Edge a r b -> Graph -> Graph
deleteEdge e@Edge{..} g = modifySinceGC (+ 1) $
    g { grChangeLog = flip updateChangeLog (grChangeLog g) $
            DeleteValues [ (encodeRes (Res edgeSrc), [ encodeRel $ outFromEdge e ])
                         , (encodeRes (Res edgeDst), [ encodeRel $ inFromEdge e ])
                         ]
      , grGraph = M.adjust (S.delete $ outFromEdge e) (Res edgeSrc)
                . M.adjust (S.delete $ inFromEdge e) (Res edgeDst)
                $ grGraph g
      }

-- | Adds a relation without making a conversion from 'Edge'.
connect :: forall r a b. Relation r a b => a -> r -> b -> Graph -> Graph
connect = case ( sing :: Sing (CardinalityFrom r a b)
               , sing :: Sing (CardinalityTo r a b)
               ) of
    (SAtMostOne, SAtMostOne) -> connectUnique
    (SAtMostOne, SUnbounded) -> connectUniqueTo
    (SUnbounded, SAtMostOne) -> connectUniqueFrom
    (SUnbounded, SUnbounded) -> connectUnbounded

-- | Adds a relation without making a conversion from 'Edge'.
--
-- Unlike 'connect', it doesn't check cardinalities.
connectUnbounded :: Relation r a b => a -> r -> b -> Graph -> Graph
connectUnbounded x r y g =
   g { grChangeLog = flip updateChangeLog (grChangeLog g) $
         InsertMany [ (encodeRes (Res x),[ encodeRel $ OutRel r x y ])
                    , (encodeRes (Res y),[ encodeRel $ InRel r x y ])
                    ]
     , grGraph = M.insertWith S.union (Res x) (S.singleton $ OutRel r x y)
               . M.insertWith S.union (Res y) (S.singleton $ InRel r x y)
               $ grGraph g
     }

-- | Connect uniquely between two given resources - e.g. make this relation
--   uniquely determining from either side.
connectUnique :: forall a r b. Relation r a b => a -> r -> b -> Graph -> Graph
connectUnique x r y = connect x r y
                    . disconnectAllFrom x r (Proxy :: Proxy b)
                    . disconnectAllTo (Proxy :: Proxy a) r y

-- | Connect uniquely from a given resource - e.g. remove all existing outgoing
--   edges of the same type first.
connectUniqueFrom :: forall a r b. Relation r a b => a -> r -> b -> Graph -> Graph
connectUniqueFrom x r y = connect x r y
                        . disconnectAllFrom x r (Proxy :: Proxy b)

-- | Connect uniquely to a given resource - e.g. remove all existing incoming
--   edges of the same type first.
connectUniqueTo :: forall a r b. Relation r a b => a -> r -> b -> Graph -> Graph
connectUniqueTo x r y = connect x r y
                      . disconnectAllTo (Proxy :: Proxy a) r y

-- | Removes a relation.
disconnect :: Relation r a b => a -> r -> b -> Graph -> Graph
disconnect x r y g = modifySinceGC (+ 1) $
    g { grChangeLog = flip updateChangeLog (grChangeLog g) $
            DeleteValues [ (encodeRes (Res x), [ encodeRel $ OutRel r x y ])
                         , (encodeRes (Res y), [ encodeRel $ InRel r x y ])
                         ]
      , grGraph = M.adjust (S.delete $ OutRel r x y) (Res x)
                . M.adjust (S.delete $ InRel r x y) (Res y)
                $ grGraph g
      }

-- | Remove all outgoing edges of the given relation type.
disconnectAllFrom :: forall a r b. Relation r a b
                  => a -> r -> Proxy b -> Graph -> Graph
disconnectAllFrom a _ _ g = foldl' (.) id (fmap deleteEdge oldEdges) $ g
  where
    oldEdges = edgesFromSrc a g :: [Edge a r b]

-- | Remove all incoming edges of the given relation type.
disconnectAllTo :: forall a r b. Relation r a b
                => Proxy a -> r -> b -> Graph -> Graph
disconnectAllTo _ _ b g = foldl' (.) id (fmap deleteEdge oldEdges) $ g
  where
    oldEdges = edgesToDst b g :: [Edge a r b]

-- | Isolate a resource from the rest of the graph. This removes
--   all relations from the node, regardless of type.
removeResource :: Resource a => a -> Graph -> Graph
removeResource r g@Graph{..} = g {
      grGraph = M.delete (Res r)
              . foldl' (.) id (fmap unhookG rels)
              $ grGraph
    , grChangeLog = updateChangeLog
                    ( DeleteKeys [encodeRes (Res r)] )
                  . updateChangeLog
                    ( DeleteValues (fmap unhookCL rels))
                  $ grChangeLog
    }
  where
    rels = maybe [] S.toList $ M.lookup (Res r) grGraph
    unhookCL rel@(InRel _ x _) = (encodeRes (Res x), [ encodeRel (inverse rel) ])
    unhookCL rel@(OutRel _ _ y) = (encodeRes (Res y), [ encodeRel (inverse rel) ])
    unhookG rel@(InRel _ x _) = M.adjust (S.delete (inverse rel)) (Res x)
    unhookG rel@(OutRel _ _ y) = M.adjust (S.delete (inverse rel)) (Res y)


-- | Merge a number of homogenously typed resources into a single
--   resource. Incoming and outgoing edge sets are merged, whilst
--   the specified combining function is used to merge the actual
--   resources.
mergeResources :: forall a. Resource a => ([a] -> a) -> [a] -> Graph -> Graph
mergeResources _ [] g = g
mergeResources f xs g@Graph{..} = g
    { grChangeLog = updateChangeLog
                   (InsertMany [ (encodeRes newRes
                                , S.toList . S.map encodeRel $ oldRels)
                                ])
                  . updateChangeLog
                      (DeleteKeys (map (encodeRes . Res) xs))
                  . foldr (.) id (fmap rehookCL $ S.toList oldRels)
                  $ grChangeLog
    , grGraph = foldr (.) id adjustments grGraph
    }
  where
    newX = f xs
    newRes = Res newX
    oldRels = foldl' S.union S.empty
            . catMaybes
            . map (\r -> M.lookup (Res r) grGraph)
            $ xs
    adjustments = M.insert newRes oldRels
                : fmap rehookG (S.toList oldRels)
                ++ map (M.delete . Res) xs
    otherEnd = \case InRel _ x _  -> Res x ; OutRel _ _ y -> Res y
    rehookG rel = M.adjust
      ( S.insert (updateOtherEnd rel newX)
      . S.delete (inverse rel)
      ) (otherEnd rel)
    rehookCL rel = updateChangeLog
        ( InsertMany [(encodeRes (otherEnd rel), [ encodeRel (updateOtherEnd rel newX) ])])
      . updateChangeLog
        ( DeleteValues [(encodeRes (otherEnd rel), [ encodeRel (inverse rel) ])])
    updateOtherEnd :: forall q. Resource q => Rel -> q -> Rel
    updateOtherEnd rel@(InRel r x (_ :: b)) y' = case eqT :: Maybe (q :~: b) of
      Just Refl -> OutRel r x y'
      Nothing -> rel
    updateOtherEnd rel@(OutRel r (_ :: b) y) x' = case eqT :: Maybe (q :~: b) of
      Just Refl -> InRel r x' y
      Nothing -> rel

-- | Remove all resources that are not connected to the rest of the graph,
-- starting from the given root set. This cleans up resources that are no
-- longer participating in the graph since they are not connected to the rest
-- and can hence safely be discarded.
--
-- This does __not__ reset garbage collection counter: if you are
-- manually invoking 'garbageCollect' with your own set of nodes, you
-- may not want to stop the major GC from happening anyway.
garbageCollect :: HashSet Res -> Graph -> Graph
garbageCollect initGrey g@Graph{..} = go initWhite initGrey
  where
    initWhite = S.fromList (M.keys grGraph) `S.difference` initGrey
    go white (S.null -> True) = g {
        grChangeLog = updateChangeLog (DeleteKeys $ map encodeRes whiteList) grChangeLog
      , grGraph = foldl' (>>>) id adjustments grGraph
    } where
      adjustments = map M.delete whiteList
      whiteList = S.toList white
    go white grey = go white' grey' where
      white' = white `S.difference` grey'
      grey' = white `S.intersection` S.unions (catMaybes nextGreys)

      nextGreys :: [Maybe (HashSet Res)]
      nextGreys = map (fmap (S.map f) . flip M.lookup grGraph) (S.toList grey)

      f (OutRel _ _ y) = Res y
      f (InRel _ x _) =  Res x

-- | Runs 'garbageCollect' preserving anything connected to root nodes
-- ('getRootNodes').
garbageCollectRoot :: Graph -> Graph
garbageCollectRoot g = setSinceGC 0 $ garbageCollect (S.fromList roots) g
  where
    roots = grRootNodes $ grGraphGCInfo g

-- | List of all edges of a given relation stemming from the provided source
-- resource to destination resources of the given type.
edgesFromSrc :: Relation r a b => a -> Graph -> [Edge a r b]
edgesFromSrc x0 g =
    let f (OutRel r x y) = liftM3 Edge (cast x) (cast r) (cast y)
        f _ = Nothing
    in maybe [] (catMaybes . map f . S.toList)
        $ M.lookup (Res x0) $ grGraph g

-- | List of all edges of a given relation incoming at the provided destination
-- resource from source resources of the given type.
edgesToDst :: Relation r a b => b -> Graph -> [Edge a r b]
edgesToDst x0 g =
    let f (InRel r x y) = liftM3 Edge (cast x) (cast r) (cast y)
        f _ = Nothing
    in maybe [] (catMaybes . map f . S.toList)
        $ M.lookup (Res x0) $ grGraph g

-- | List of all nodes connected through a given relation with a provided source
-- resource.
connectedTo :: forall a r b. Relation r a b
            => a -> r -> Graph -> Quantify (CardinalityTo r a b) b
connectedTo a r g =
    let rs = mapMaybe (\(Res x) -> cast x :: Maybe b) $ anyConnectedTo a r g
     in case sing :: Sing (CardinalityTo r a b) of
          SAtMostOne -> listToMaybe rs
          SUnbounded -> rs
  where
    -- Get rid of unused warnings
    _ = undefined :: (SCardinality c, Proxy AtMostOneSym0, Proxy UnboundedSym0)

-- | List of all nodes connected through a given relation with a provided
--   destination resource.
connectedFrom :: forall a r b . Relation r a b
              => r -> b -> Graph -> Quantify (CardinalityFrom r a b) a
connectedFrom r b g =
    let rs = mapMaybe (\(Res x) -> cast x :: Maybe a) $ anyConnectedFrom r b g
     in case sing :: Sing (CardinalityFrom r a b) of
          SAtMostOne -> listToMaybe rs
          SUnbounded -> rs

-- | List of all nodes connected through a given relation with a provided source
-- resource.
anyConnectedTo :: forall a r . (Resource a, Typeable r) => a -> r -> Graph -> [Res]
anyConnectedTo x0 _ g =
    let f (OutRel r _ y) = Just (Res y) <* (cast r :: Maybe r)
        f _ = Nothing
    in maybe [] (catMaybes . map f . S.toList)
        $ M.lookup (Res x0) $ grGraph g

-- | List of all nodes connected through a given relation with a provided
--   destination resource.
anyConnectedFrom :: forall r b . (Typeable r, Resource b) => r -> b -> Graph -> [Res]
anyConnectedFrom _ x0 g =
    let f (InRel r x _) = Just (Res x) <* (cast r :: Maybe r)
        f _ = Nothing
    in maybe [] (catMaybes . map f . S.toList)
        $ M.lookup (Res x0) $ grGraph g

-- | More convenient version of 'memberEdge'.
isConnected :: Relation r a b => a -> r -> b -> Graph -> Bool
isConnected x r y g = memberEdge (Edge x r y) g

-- | Yields the change log of modifications done to the graph, and the graph
-- with the change log removed.
takeChangeLog :: Graph -> (ChangeLog, Graph)
takeChangeLog g = ( grChangeLog g
                  , g { grChangeLog = emptyChangeLog }
                  )

-- | Creates a graph from key value pairs.
-- No key is duplicated in the input and no value appears twice for a given key.
buildGraph :: StoreChan -> RemoteTable -> (MetaInfo, [(Key,[Value])]) -> Graph
buildGraph mmchan rt (mi, kvs) = (\hm -> Graph mmchan emptyChangeLog hm gcInfo)
    . M.fromList
    . map (decodeRes rt *** S.fromList . map (decodeRel rt))
    $ kvs
  where
    gcInfo = GraphGCInfo (_miSinceGC mi)
                         (_miGCThreshold mi)
                         (map (decodeRes rt) (_miRootNodes mi))

-- | Builds an empty 'Graph' with the given 'StoreChan'.
emptyGraph :: StoreChan -> Graph
emptyGraph mmchan = Graph mmchan emptyChangeLog M.empty defaultGraphGCInfo

-- | Updates the multimap store with the latest changes to the graph.
--
-- Runs the given callback after the changes are replicated.
-- Only fast calls that do not throw exceptions should be used there.
--
-- Runs 'garbageCollectRoot' if the garbage collection counter
-- ('getSinceGC') passes the GC meets or passes the GC threshold value
-- ('getGCThreshold').
sync :: Graph -> Process () -> Process Graph
sync g cb = do
    (cl, g') <- takeChangeLog <$> runGCIfThresholdMet g
    updateStore (grMMChan g) (fromChangeLog cl) cb
    return g'
  where
    shouldGC :: Graph -> Bool
    shouldGC gr = let gi = grGraphGCInfo gr
                  in grGCThreshold gi > 0 && grSinceGC gi >= grGCThreshold gi

    runGCIfThresholdMet :: Graph -> Process Graph
    runGCIfThresholdMet gr =
      if shouldGC gr then do
        let gr' = garbageCollectRoot gr
            beforeGCSize = M.size (grGraph gr)
        seq beforeGCSize $ rgTrace $ "Garbage collecting " ++ show beforeGCSize
                                     ++ " nodes ..."
        let afterGCSize = M.size (grGraph gr')
        seq afterGCSize $ rgTrace $ "After GC, " ++ show afterGCSize
                                    ++ " nodes remain."
        return gr'
      else return gr

-- | Retrieves the graph from the multimap store.
getGraph :: StoreChan -> Process Graph
getGraph mmchan = do
  rt <- fmap (remoteTable . processNode) ask
  buildGraph mmchan rt <$> HA.Multimap.getStoreValue mmchan

fromStrict :: ByteString -> Lazy.ByteString
fromStrict = fromChunks . (:[])

toStrict :: Lazy.ByteString -> ByteString
toStrict = Strict.concat . toChunks

-- | Encodes a Res into a 'Lazy.ByteString'.
encodeRes :: Res -> ByteString
encodeRes (Res (r :: r)) =
    toStrict $ encode ($(mkStatic 'someResourceDict) `staticApply`
                       (resourceDict :: Static (Dict (Resource r)))) `append`
    runPutLazy (safePut r)

-- | Decodes a Res from a 'Lazy.ByteString'.
decodeRes :: RemoteTable -> ByteString -> Res
decodeRes rt bs =
    case runGetOrFail get $ fromStrict bs of
      Right (rest,_,d) -> case unstatic rt d of
        Right (SomeResourceDict (Dict :: Dict (Resource s))) ->
          case runGetLazy safeGet rest of
            Right r -> Res (r :: s)
            Left err -> error $ "decodeRes: runGetLazy: " ++ err
        Left err -> error $ "decodeRes: " ++ err
      Left (_,_,err) -> error $ "decodeRes: " ++ err

encodeRel :: Rel -> ByteString
encodeRel (InRel (r :: r) (x :: a) (y :: b)) =
  toStrict $ encode ($(mkStatic 'someRelationDict) `staticApply`
                (relationDict :: Static (Dict (Relation r a b))))
            `append` runPutLazy (safePut (0 :: Word8, r, x, y))
encodeRel (OutRel (r :: r) (x :: a) (y :: b)) =
  toStrict $ encode ($(mkStatic 'someRelationDict) `staticApply`
                (relationDict :: Static (Dict (Relation r a b))))
            `append` runPutLazy (safePut (1 :: Word8, r, x, y))

decodeRel :: RemoteTable -> ByteString -> Rel
decodeRel rt bs = case runGetOrFail get $ fromStrict bs of
  Right (rest,_,d) -> case unstatic rt d of
    Right (SomeRelationDict (Dict :: Dict (Relation r a b))) ->
      case runGetLazy safeGet rest :: Either String (Word8, r, a, b) of
        Right (b, r, x, y) -> case b of
          (0 :: Word8) -> InRel r x y
          (1 :: Word8) -> OutRel r x y
          _ -> error $ "decodeRel: Invalid direction bit."
        Left err -> error $ "decodeRel: runGetLazy: " ++ err
    Left err -> error $ "decodeRel: " ++ err
  Left (_,_,err) -> error $ "decodeRel: " ++ err

getGraphResources :: Graph -> [(Res, [Rel])]
getGraphResources = fmap (second S.toList) . M.toList . grGraph

-- | Get all resources in the graph of a particular type.
getResourcesOfType :: forall a. Resource a
                   => Graph
                   -> [a]
getResourcesOfType =
    mapMaybe (\(Res x) -> cast x :: Maybe a)
  . fst . unzip
  . getGraphResources

-- * GC control

-- | Modify the 'GraphGCInfo' in the given graph.
modifyGCInfo :: (GraphGCInfo -> GraphGCInfo) -> Graph -> Graph
modifyGCInfo f g = g
  { grGraphGCInfo = newGI
  , grChangeLog = updateChangeLog (SetMetaInfo mi) (grChangeLog g) }
  where
    newGI = f $ grGraphGCInfo g

    mi :: MetaInfo
    mi = MetaInfo (grSinceGC newGI)
                  (grGCThreshold newGI)
                  (map encodeRes $ grRootNodes newGI)

-- | Modifies the count of disconnects since the last time automatic
-- major GC was ran.
modifySinceGC :: (Int -> Int) -> Graph -> Graph
modifySinceGC f = modifyGCInfo (\gi -> gi { grSinceGC = f $ grSinceGC gi })

-- | Gets the rough number of disconnects since the last time
-- automatic major GC was ran.
getSinceGC :: Graph -> Int
getSinceGC = grSinceGC . grGraphGCInfo

-- | Sets the rough number of disconnects since the last time
-- automatic major GC was ran.
setSinceGC :: Int -> Graph -> Graph
setSinceGC i = modifySinceGC (const i)

-- | Adds the given resource to the set of root nodes used during GC.
addRootNode :: Resource a => a -> Graph -> Graph
addRootNode res = modifyRootNodes (Res res :)

-- | Removes the given node from the root list used during GC.
removeRootNode :: Resource a => a -> Graph -> Graph
removeRootNode res = modifyRootNodes (Data.List.delete (Res res))

modifyRootNodes :: ([Res] -> [Res]) -> Graph -> Graph
modifyRootNodes f = modifyGCInfo (\gi -> gi { grRootNodes = f $ grRootNodes gi })

-- | Checks if the given node is rooted.
isRootNode :: Resource a => a -> Graph -> Bool
isRootNode res g = Res res `elem` grRootNodes (grGraphGCInfo g)

-- | Retrieve root nodes of the given graph.
getRootNodes :: Graph -> [Res]
getRootNodes = grRootNodes . grGraphGCInfo

-- | Modify the disconnect threshold at which the automatic GC runs
-- upon sync. If the value is @<= 0@, the GC is disabled.
modifyGCThreshold :: (Int -> Int) -> Graph -> Graph
modifyGCThreshold f =
  modifyGCInfo (\gi -> gi { grGCThreshold = f $ grGCThreshold gi })

-- | Get the disconnect threshold at which the automatic GC runs
-- upon sync. If the value is @<= 0@, the GC is disabled.
getGCThreshold :: Graph -> Int
getGCThreshold = grGCThreshold . grGraphGCInfo

-- | Set the disconnect threshold at which the automatic GC runs
-- upon sync. Set the value to @<= 0@ in order to disable the GC.
setGCThreshold :: Int -> Graph -> Graph
setGCThreshold i = modifyGCThreshold (const i)

-- | Internally used default 'GraphGCInfo'. It is just like
-- 'defaultMetaInfo' but sets the (empty) list of root nodes directly.
defaultGraphGCInfo :: GraphGCInfo
defaultGraphGCInfo = GraphGCInfo (_miSinceGC mi) (_miGCThreshold mi) []
  where
    mi = defaultMetaInfo
