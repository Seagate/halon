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
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
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
    -- * Operations
    , newResource
    , insertEdge
    , deleteEdge
    , connect
    , connectUnique
    , connectUniqueFrom
    , connectUniqueTo
    , disconnect
    , disconnectAllFrom
    , disconnectAllTo
    , mergeResources
    , sync
    , getGraph
    , garbageCollect
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
    ) where

import HA.Multimap
  ( Key
  , Value
  , StoreUpdate(..)
  , updateStore
  , getKeyValuePairs
  )
import HA.Multimap.Implementation

import Control.Distributed.Process ( ProcessId, Process )
import Control.Distributed.Process.Internal.Types
    ( remoteTable, processNode )
import Control.Distributed.Process.Serializable ( Serializable )
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
import Data.Binary ( Binary(..), decode, encode )
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
import Data.List (foldl')
import Data.Maybe
import Data.Proxy
import Data.Typeable ( Typeable, cast )
import Data.Word (Word8)

-- | A type can be declared as modeling a resource by making it an instance of
-- this class.
class (Eq a, Hashable a, Serializable a, Show a) => Resource a where
  resourceDict :: Static (Dict (Resource a))

deriving instance Typeable Resource

-- | A relation on resources specifies what relationships can exist between
-- any two given types of resources. Two resources of type @a@, @b@, cannot be
-- related through @r@ if an @Relation r a b@ instance does not exist.
class (Hashable r, Serializable r, Resource a, Resource b, Show r) => Relation r a b where
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
    hashWithSalt s (Res x) = s `hashWithSalt` x

instance Hashable Rel where
    hashWithSalt s (InRel r a b) =
        s `hashWithSalt` (0 :: Int) `hashWithSalt` r `hashWithSalt` a `hashWithSalt` b
    hashWithSalt s (OutRel r a b) =
        s `hashWithSalt` (1 :: Int) `hashWithSalt` r `hashWithSalt` a `hashWithSalt` b

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

-- XXX Specialized existential datatypes required because 'remotable' does not
-- yet support higher kinded type variables.

data SomeResourceDict = forall a. SomeResourceDict (Dict (Resource a))
    deriving Typeable
data SomeRelationDict = forall r a b. SomeRelationDict (Dict (Relation r a b))
    deriving Typeable

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

-- | A change log for graph updates.
--
-- Has a multimap with insertions of nodes and edges, a multimap with removals
-- of edges and a set of removals of nodes.
--
-- The structure must preserve the following invariants:
-- * Edges in the insertion multimap are not present in the removal multimap.
-- * Nodes in the insertion multimap are not present in the removal set.
-- * Nodes in the removal multimap are not present in removal set.
data ChangeLog = ChangeLog !Multimap !Multimap !(HashSet Key)
  deriving Typeable

-- | Gets a list of updates and produces a possibly shorter equivalent list.
--
-- The updates are compressed by merging the multiple updates that could be
-- found for a given key.
updateChangeLog :: StoreUpdate -> ChangeLog -> ChangeLog
updateChangeLog x (ChangeLog is dvs dks) = case x of
    InsertMany kvs ->
       ChangeLog (insertMany kvs is) (deleteValues kvs dvs)
                 (foldr S.delete dks $ map fst kvs)
    DeleteValues kvs ->
      let kvs' = filter (not . flip S.member dks . fst) kvs
       in ChangeLog (deleteValues kvs is) (insertMany kvs' dvs) dks
    DeleteKeys ks ->
      ChangeLog (deleteKeys ks is) (deleteKeys ks dvs) (foldr S.insert dks ks)

-- | Gets the list of updates from the changelog.
fromChangeLog :: ChangeLog -> [StoreUpdate]
fromChangeLog (ChangeLog is dvs dks) =
    [ InsertMany   $ toList is
    , DeleteValues $ toList dvs
    , DeleteKeys   $ S.toList dks
    ]

-- | An empty changelog
emptyChangeLog :: ChangeLog
emptyChangeLog = ChangeLog empty empty S.empty

-- | The graph
data Graph = Graph
  { -- | Pid of the multimap which replicates the graph.
    grMMId :: ProcessId
    -- | Changes in the graph with respect to the version stored in the multimap.
  , grChangeLog :: !ChangeLog
    -- | The graph.
  , grGraph :: HashMap Res (HashSet Rel)
  } deriving (Typeable)

-- | Edges between resources. Edge types are called relations. An edge is an
-- element of some relation. The order of the fields matches that of
-- subject-verb-object triples in RDF.
data Edge a r b =
    Edge { edgeSrc      :: !a
         , edgeRelation :: !r
         , edgeDst      :: !b }
  deriving Eq

-- | Returns @True@ iff the graph is empty.
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
deleteEdge e@Edge{..} g =
    g { grChangeLog = flip updateChangeLog (grChangeLog g) $
            DeleteValues [ (encodeRes (Res edgeSrc), [ encodeRel $ outFromEdge e ])
                         , (encodeRes (Res edgeDst), [ encodeRel $ inFromEdge e ])
                         ]
      , grGraph = M.adjust (S.delete $ outFromEdge e) (Res edgeSrc)
                . M.adjust (S.delete $ inFromEdge e) (Res edgeDst)
                $ grGraph g
      }

-- | Adds a relation without making a conversion from 'Edge'.
connect :: Relation r a b => a -> r -> b -> Graph -> Graph
connect x r y g =
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
disconnect x r y g =
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

-- | Merge a number of homogenously typed resources into a single
--   resource. Incoming and outgoing edge sets are merged, whilst
--   the specified combining function is used to merge the actual
--   resources.
mergeResources :: Resource a => ([a] -> a) -> [a] -> Graph -> Graph
mergeResources _ [] g = g
mergeResources f xs g@Graph{..} = let
    newRes = Res $ f xs
    oldRels = foldl' S.union S.empty
            . catMaybes
            . map (\r -> M.lookup (Res r) grGraph)
            $ xs
    adjustments = M.insert newRes oldRels
                : map (M.delete . Res) xs
  in g {
          grChangeLog = updateChangeLog
                       (InsertMany [ (encodeRes newRes
                                    , S.toList . S.map encodeRel $ oldRels)
                                    ])
                      $ updateChangeLog
                          (DeleteKeys (map (encodeRes . Res) xs)) grChangeLog
        , grGraph = foldr (.) id adjustments grGraph
       }

-- | Remove all resources that are not connected to the rest of the graph,
-- starting from the given root set. This cleans up resources that are no
-- longer participating in the graph since they are not connected to the rest
-- and can hence safely be discarded.
garbageCollect :: Resource a => [a] -> Graph -> Graph
garbageCollect rootSet g@Graph{..} = go S.empty initWhite initGrey
  where
    initWhite = (S.fromList $ M.keys grGraph) `S.difference` initGrey
    initGrey = S.fromList $ map Res rootSet
    go _ white (S.null -> True) = g {
        grChangeLog = updateChangeLog (DeleteKeys $ map encodeRes whiteList)
                        grChangeLog
      , grGraph = foldl' (>>>) id adjustments grGraph
    } where
      adjustments = (map M.delete whiteList)
      whiteList = S.toList white

    go black white grey@(S.toList -> greyHead : _) = go black' white' grey' where
      black' = S.insert greyHead black
      white' = white `S.difference` newGrey
      grey' = (S.delete greyHead grey) `S.union` newGrey
      newGrey = white `S.intersection` (maybe S.empty (S.map f)
                                    $ M.lookup greyHead grGraph)
      f (OutRel _ _ y) = Res y
      f (InRel _ x _) =  Res x
    go _ _ _ = error "garbageCollect: Impossible."

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
connectedTo :: forall a r b . Relation r a b => a -> r -> Graph -> [b]
connectedTo a r g = mapMaybe (\(Res x) -> cast x) $ anyConnectedTo a r g

-- | List of all nodes connected through a given relation with a provided
--   destination resource.
connectedFrom :: forall a r b . Relation r a b => r -> b -> Graph -> [a]
connectedFrom r b g = mapMaybe (\(Res x) -> cast x) $ anyConnectedFrom r b g

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
buildGraph :: ProcessId -> RemoteTable -> [(Key,[Value])] -> Graph
buildGraph mmpid rt = Graph mmpid emptyChangeLog
    . M.fromList
    . map (decodeRes rt *** S.fromList . map (decodeRel rt))

-- | Updates the multimap store with the latest changes to the graph.
sync :: Graph -> Process Graph
sync g =
    updateStore (grMMId g) (fromChangeLog cl)
      >>= return . maybe (error "sync: updating the multimap store") (const g')
  where
    (cl, g') = takeChangeLog g

-- | Retrieves the graph from the multimap store.
getGraph :: ProcessId -> Process Graph
getGraph mmpid = do
  rt <- fmap (remoteTable . processNode) ask
  getKeyValuePairs mmpid
    >>= maybe (error "getGraph: retriving pairs from store")
              (return . buildGraph mmpid rt)

fromStrict :: ByteString -> Lazy.ByteString
fromStrict = fromChunks . (:[])

toStrict :: Lazy.ByteString -> ByteString
toStrict = Strict.concat . toChunks

-- | Encodes a Res into a 'Lazy.ByteString'.
encodeRes :: Res -> ByteString
encodeRes (Res (r :: r)) =
    toStrict $ encode ($(mkStatic 'someResourceDict) `staticApply`
                       (resourceDict :: Static (Dict (Resource r)))) `append`
    encode r

-- | Decodes a Res from a 'Lazy.ByteString'.
decodeRes :: RemoteTable -> ByteString -> Res
decodeRes rt bs =
    case runGetOrFail get $ fromStrict bs of
      Right (rest,_,d) -> case unstatic rt d of
        Right (SomeResourceDict (Dict :: Dict (Resource s))) -> Res (decode rest :: s)
        Left err -> error $ "decodeRes: " ++ err
      Left (_,_,err) -> error $ "decodeRes: " ++ err

encodeRel :: Rel -> ByteString
encodeRel (InRel (r :: r) (x :: a) (y :: b)) =
  toStrict $ encode ($(mkStatic 'someRelationDict) `staticApply`
                (relationDict :: Static (Dict (Relation r a b))))
            `append` encode (0 :: Word8, r, x, y)
encodeRel (OutRel (r :: r) (x :: a) (y :: b)) =
  toStrict $ encode ($(mkStatic 'someRelationDict) `staticApply`
                (relationDict :: Static (Dict (Relation r a b))))
            `append` encode (1 :: Word8, r, x, y)

decodeRel :: RemoteTable -> ByteString -> Rel
decodeRel rt bs = case runGetOrFail get $ fromStrict bs of
  Right (rest,_,d) -> case unstatic rt d of
    Right (SomeRelationDict (Dict :: Dict (Relation r a b))) ->
      let (b, r, x, y) = decode rest :: (Word8, r, a, b)
      in case b of
        (0 :: Word8) -> InRel r x y
        (1 :: Word8) -> OutRel r x y
        _ -> error $ "decodeRel: Invalid direction bit."
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
