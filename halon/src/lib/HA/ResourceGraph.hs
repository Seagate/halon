-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ConstraintKinds #-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module HA.ResourceGraph
    ( -- * Types
      Resource(..)
    , Relation(..)
    , Graph
    , GL.Edge(..)
    , Dict(..)
    , Res(..)
    , Rel(..)
    , Cardinality(..)
    , StorageIndex(..)
    , StorageResource(..)
    , StorageRelation(..)
    -- , Quantify(..)
    -- * Operations
    , insertEdge
    , GL.deleteEdge
    , connect
    , GL.disconnect
    , GL.disconnectAllFrom
    , GL.disconnectAllTo
    , GL.removeResource
    , mergeResources
    , sync
    , emptyGraph
    , getGraph
    , garbageCollect
    , garbageCollectRoot
    -- * Queries
    , GL.null
    , GL.memberResource
    , GL.memberEdge
    , GL.memberEdgeBack
    , GL.edgesFromSrc
    , GL.edgesToDst
    , asUnbounded
    , cardinalities
    , connectedFrom
    , connectedTo
    , GL.anyConnectedFrom
    , GL.anyConnectedTo
    , GL.isConnected
    , HA.ResourceGraph.__remoteTable
    , getGraphResources
    , getResourcesOfType
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
    -- * Testing
    , getStoreUpdates
    , mkStorageResourceKeyName
    , mkStorageRelationKeyName
    , mkResourceKeyName
    , mkRelationKeyName
    , SomeStorageResourceDict(..)
    , SomeStorageRelationDict(..)
    , someStorageResourceDict
    , someStorageRelationDict
    , someResourceDict
    , someRelationDict
    , someResourceDict__static
    , someRelationDict__static
    , GraphGCInfo(..)
    , genStorageRelationKeyName
    , genStorageResourceKeyName
    , SomeResourceDict(..)
    , SomeRelationDict(..)
      -- * Migration
    , setChangeLog
    , buildGraph
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
import HA.ResourceGraph.GraphLike
  ( ChangeLog(..)
  , Edge(..)
  , emptyChangeLog
  , fromChangeLog
  , updateChangeLog
  )
import qualified HA.ResourceGraph.GraphLike as GL

import Control.Distributed.Process ( Process )
import Control.Distributed.Process.Internal.Types
    ( remoteTable, processNode )
import Control.Distributed.Static
  ( RemoteTable
  , Static
  , staticLabel
  )
import Control.Distributed.Process.Closure
import Data.Constraint ( Dict(..) )

import Prelude hiding (null)
import Control.Arrow ( (***), (>>>), second )
import Control.Monad ( liftM3 )
import Control.Lens (makeLenses)
import Control.Monad.Reader ( ask )
import Data.Binary ( encode )
import qualified Data.ByteString as Strict ( concat )
import Data.ByteString ( ByteString )
import Data.ByteString.Lazy as Lazy ( toChunks )
import qualified Data.ByteString.Lazy as Lazy ( ByteString )
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as M
import Data.HashSet (HashSet)
import qualified Data.HashSet as S
import Data.Hashable
import Data.List (foldl', delete, intercalate)
import Data.UUID (UUID, fromString)
import qualified Data.UUID as UUID
import Data.Maybe
import Data.Monoid
import Data.Proxy
import Data.Serialize.Put (runPutLazy)
import Data.Singletons.TH
import Data.Typeable
import Data.Word (Word8)
import GHC.Generics (Generic)
import HA.SafeCopy
import qualified HA.Aeson as A

rgTrace :: String -> Process ()
rgTrace = mkHalonTracer "RG"

-- | The index of the type inside a graph. Each type that persists
-- in a graph should have this constraint. So we could lookup dictionaries
-- for this type.
--
-- This is needed because when schema changes some types may completely
-- change but we stil need to be able to work with them. See 'StorageResource'
-- for more details.
class StorageIndex a where typeKey :: proxy a -> UUID

instance StorageIndex UUID where
  typeKey _ = fromJust $ fromString "d2947f30-2858-4bce-b71f-0fa9b6ca64f1"

-- |
-- This type class denotes that value of this type may present in resource
-- graph storage. Such values may be there if schema changes, and application
-- should know how to work with them.
--
-- Examples:
--
--   * If resources uses safe copy for an update it can just provide all
--     required instances and 'StorageIndex' of the type remains unchanged.
--     Then application can load required instances and update record using
--     safe copy methods.
--   * If one resource is exchanged to a completely different resource, e.g.
--     older version had:
--     .
--     >>> data Device = Device UUID
--     .
--     and newever version uses:
--     .
--     >>> data Device = Device Path
--     .
--     It's impossible to use safecopy to update here. Instead following strategy
--     should be used.
--     1. Old type should be moved to a special module and new one introduced.
--     2. We load unrestricted graph and can work with valus of this type, but
--     it will not allow us to store such values.
--
-- It's important that 'StorageMember' instance should not be removed for a
-- type even if type is no longer a part of the schema.
class (Eq a, Hashable a, Typeable a, SafeCopy a, Show a, StorageIndex a, A.ToJSON a)
  => StorageResource a where
  storageResourceDict :: Static (Dict (StorageResource a))

deriving instance Typeable StorageResource

mkStorageResourceKeyName :: StorageResource a => proxy a -> String
mkStorageResourceKeyName p = genStorageResourceKeyName (typeKey p)

genStorageResourceKeyName :: UUID -> String
genStorageResourceKeyName u = "storage:" ++ (UUID.toString u)

-- | A type can be declared as modeling a resource by making it an instance of
-- this class.
--
-- The only difference with the 'StorageMember' is that 'Resource' class
-- denotes that Resource is a part of the schema for the current version.
-- Only values with 'Resource' constraint can be used in Restricted (Typed) graph.
class StorageResource a => Resource a where
  resourceDict :: Static (Dict (Resource a))

deriving instance Typeable Resource

-- | Make resource key for the given type.
mkResourceKeyName :: Resource a => proxy a -> String
mkResourceKeyName p = genResourceKeyName (typeKey p)

-- | Generate dictionariy key for the resource.
genResourceKeyName :: UUID -> String
genResourceKeyName u = "resource:" ++ (UUID.toString u)

-- The cardinalities of relations allow for at most one element
-- or any amount of elements.
$(singletons [d|
  data Cardinality = AtMostOne | Unbounded
    deriving Show
  |])

-- | Determines how many values of a type can be yielded according to
-- the cardinality.
type family Quantify (c :: Cardinality) = (r :: * -> *) | r -> c where
  Quantify 'AtMostOne = Maybe
  Quantify 'Unbounded = []

-- | Returns a pair of cardinalities at "from" and "to" sides of a relation.
cardinalities :: forall r a b. Relation r a b
              => Proxy r -> Proxy a -> Proxy b -> (Cardinality, Cardinality)
cardinalities _ _ _ = let a = sing :: Sing (CardinalityFrom r a b)
                          b = sing :: Sing (CardinalityTo r a b)
                      in (fromSing a, fromSing b)

-- | A relation that can exist in the storage of the ResourceGraph.
-- See examples of use in 'StorageResource' type class
class (StorageResource r, StorageResource a, StorageResource b) => StorageRelation r a b where
  storageRelationDict :: Static (Dict (StorageRelation r a b))

-- | Make storage relation name for the given type.
mkStorageRelationKeyName :: StorageRelation r a b => (proxy r, proxy a, proxy b) -> String
mkStorageRelationKeyName (pr, pa, pb) = genStorageRelationKeyName (typeKey pr) (typeKey pa) (typeKey pb)

-- | Generate storage relation name in the database.
genStorageRelationKeyName :: UUID -> UUID -> UUID -> String
genStorageRelationKeyName ur ua ub =  "storage:" ++
  intercalate "_"
    [ UUID.toString ur
    , UUID.toString ua
    , UUID.toString ub
    ]

-- | A relation on resources specifies what relationships can exist between
-- any two given types of resources. Two resources of type @a@, @b@, cannot be
-- related through @r@ if an @Relation r a b@ instance does not exist.
class ( StorageRelation r a b, Resource a, Resource b
      , SingI (CardinalityFrom r a b), SingI (CardinalityTo r a b))
      => Relation r a b where
  type CardinalityFrom r a b :: Cardinality
  type CardinalityTo r a b :: Cardinality
  relationDict :: Static (Dict (Relation r a b))

deriving instance Typeable Relation

-- | Make relation name for the given type.
mkRelationKeyName :: Relation r a b => (proxy r, proxy a, proxy b) -> String
mkRelationKeyName (pr, pa, pb) = genRelationKeyName (typeKey pr) (typeKey pa) (typeKey pb)

-- | Generate relation name in the database.
genRelationKeyName :: UUID -> UUID -> UUID -> String
genRelationKeyName ur ua ub = "relation:" ++
  intercalate "_"
    [ UUID.toString ur
    , UUID.toString ua
    , UUID.toString ub
    ]


-- | An internal wrapper for resources to have one universal type of resources.
data Res = forall a. Resource a => Res !a

-- | Short for "relationship". A relationship in an element of a relation.
-- A relationship is synomymous to an edge. Relationships are not type indexed
-- and are internal to this module. Edges are external representations of
-- a relationship.
data Rel = forall r a b. Relation r a b => InRel !r a b
         | forall r a b. Relation r a b => OutRel !r a b

deriving instance Show Rel

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

instance A.ToJSON Res where
  toJSON (Res x) = A.toJSON x

-- XXX Specialized existential datatypes required because 'remotable' does not
-- yet support higher kinded type variables.

data SomeStorageResourceDict = forall a. SomeStorageResourceDict (Dict (StorageResource a))
    deriving Typeable
data SomeResourceDict = forall a. SomeResourceDict (Dict (Resource a))
    deriving Typeable
data SomeStorageRelationDict = forall r a b. SomeStorageRelationDict (Dict (StorageRelation r a b))
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
    grSinceGC :: !Int
    -- | Amount of disconnects after which the GC should be ran. There
    -- is no guarantee that GC will run after precisely after this
    -- many. If the value is not a positive integer, the automatic GC
    -- won't be ran at all. Defaults to @100@.
  , grGCThreshold :: !Int
    -- | Set of nodes that we consider as being roots
  , grRootNodes :: ![Res]
  } deriving (Eq, Typeable, Generic, Show)

-- XXX Wrapper functions because 'remotable' doesn't like constructors names.

someResourceDict :: Dict (Resource a) -> SomeResourceDict
someResourceDict = SomeResourceDict

someRelationDict :: Dict (Relation r a b) -> SomeRelationDict
someRelationDict = SomeRelationDict

someStorageResourceDict :: Dict (StorageResource a) -> SomeStorageResourceDict
someStorageResourceDict = SomeStorageResourceDict

someStorageRelationDict :: Dict (StorageRelation r a b) -> SomeStorageRelationDict
someStorageRelationDict = SomeStorageRelationDict

remotable ['someResourceDict, 'someRelationDict]

instance GL.DirectedEdge Rel where

  direction (InRel _ _ _) = GL.In
  direction (OutRel _ _ _) = GL.Out

  -- | Invert a relation
  invert (OutRel a b c) = InRel a b c
  invert (InRel a b c) = OutRel a b c

-- | Treat a relationship as unbounded, regardless of whether it is or not.
asUnbounded :: forall card c. (SingI card)
            => Quantify card c
            -> [c]
asUnbounded = case (sing :: Sing card) of
  SAtMostOne -> maybeToList
  SUnbounded -> id

-- | The graph
data Graph = Graph
  { -- | Channel used to communicate with the multimap which replicates the
    -- graph.
    _grMMChan :: StoreChan
    -- | Changes in the graph with respect to the version stored in the multimap.
  , _grChangeLog :: !GL.ChangeLog
    -- | The graph.
  , _grGraph :: !(HashMap Res (HashSet Rel))
    -- | Metadata about the graph GC
  , grGraphGCInfo :: !GraphGCInfo
  } deriving (Typeable)

makeLenses ''Graph

instance Show Graph where
  show g = show $ _grGraph g

-- | Create a proxy out of value.
proxy :: r -> Proxy r
proxy _ = Proxy

-- Update plan, because graph is not covered by the safecopy we need to be able
-- to distinguish with old and new states, this is done in the following way:
--
-- Version1: message is started with Static (Dict SomeRelation)
-- Version2: message is started with Static (Dict SomeRelation) with value ""
--   such value is not legal for version1.
-- Version3: staticLabel "" :: Static (Dict SomeRelation) is removed from the
--   message.
--
-- Algorithm is the following:
-- Version1->Version2: we can check if we have staticLabel "" in the beginning
-- if so we decode Version2 otherwise Version1 and always store that as Version2.
--
-- Version2->Version3: we can check if we have staticLabel "" in the beginning
-- then we decode as Version2 otherwise as Version3 and always store that as
-- Version3.
--
-- Update path:
-- 1. Version1
-- 2. Version1->Version2
-- 3. Version2->Version3 (store as V2)
-- 4. Version2->Version3 (store as V3)
-- 5. Version3
--
-- Downgrades are possible only between 2 consequent versions (non transitive).

instance GL.GraphLike Graph where
  type InsertableRes Graph = Resource
  type InsertableRel Graph = Relation

  type Resource Graph = Resource
  type Relation Graph = Relation

  type UniversalResource Graph = Res
  type UniversalRelation Graph = Rel

  encodeUniversalResource (Res (r :: r)) = toStrict $
    encode (staticLabel "" :: Static SomeResourceDict)
    <> encode (typeKey (Proxy :: Proxy r))
    <> runPutLazy (safePut r)

  encodeUniversalRelation (InRel (r :: r) (x :: a) (y :: b)) = toStrict $
    encode (staticLabel "" :: Static SomeRelationDict)
    <> encode ( typeKey (proxy r)
              , typeKey (proxy x)
              , typeKey (proxy y))
    <> runPutLazy (safePut (0 :: Word8, r, x, y))
  encodeUniversalRelation (OutRel (r :: r) (x :: a) (y :: b)) = toStrict $
    encode (staticLabel "" :: Static SomeRelationDict)
    <> encode ( typeKey (proxy r)
              , typeKey (proxy x)
              , typeKey (proxy y))
    <> runPutLazy (safePut (1 :: Word8, r, x, y))

  -- | Decodes a Res from a 'Lazy.ByteString'.
  decodeUniversalResource = GL.decodeAnyResource
     (Proxy :: Proxy Resource)
     (\(SomeResourceDict (Dict :: Dict (Resource a))) -> GL.A (Dict :: Dict (Resource a)))
     genResourceKeyName
     Res
  decodeUniversalRelation = GL.decodeAnyRelation
     (Proxy :: Proxy Relation)
     (\(SomeRelationDict (Dict :: Dict (Relation r a b))) -> GL.A3 (Dict :: Dict (Relation r a b)))
     genRelationKeyName
     InRel
     OutRel

  decodeRes :: forall a. Resource a => Res -> Maybe a
  decodeRes (Res a) = cast a :: Maybe a
  decodeRel :: forall r a b. Relation r a b => Rel -> Maybe (Edge a r b)
  decodeRel (OutRel r s d) = liftM3 Edge (cast s) (cast r) (cast d)
  decodeRel (InRel r s d) = liftM3 Edge (cast s) (cast r) (cast d)

  encodeIRes = Res
  encodeIRelIn (Edge s r d) = InRel r s d
  encodeIRelOut (Edge s r d) = OutRel r s d

  explodeRel :: Rel -> (Res, GL.Any, Res)
  explodeRel (OutRel r s d) = (Res s, GL.Any r, Res d)
  explodeRel (InRel r s d) = (Res s, GL.Any r, Res d)

  queryRes r g =
    let res = Res r
    in if res `M.member` (_grGraph g) then Just res else Nothing
  queryRel e GL.In hs =
    let rel = GL.encodeIRelIn e
    in if rel `S.member` hs then Just rel else Nothing
  queryRel e GL.Out hs =
    let rel = GL.encodeIRelOut e
    in if rel `S.member` hs then Just rel else Nothing

  incrementGC = modifySinceGC (+ 1)

  graph = grGraph

  storeChan = grMMChan

  changeLog = grChangeLog

-- | Connect source and destination resources through a directed edge.
insertEdge :: Relation r a b => Edge a r b -> Graph -> Graph
insertEdge Edge{..} = connect edgeSrc edgeRelation edgeDst

-- | Adds a relation without making a conversion from 'Edge'.
connect :: forall r a b. Relation r a b => a -> r -> b -> Graph -> Graph
connect = case ( sing :: Sing (CardinalityFrom r a b)
               , sing :: Sing (CardinalityTo r a b)
               ) of
    (SAtMostOne, SAtMostOne) -> GL.connectUnique
    (SAtMostOne, SUnbounded) -> GL.connectUniqueTo
    (SUnbounded, SAtMostOne) -> GL.connectUniqueFrom
    (SUnbounded, SUnbounded) -> GL.connectUnbounded

-- | Merge a number of homogenously typed resources into a single
--   resource. Incoming and outgoing edge sets are merged, whilst
--   the specified combining function is used to merge the actual
--   resources.
mergeResources :: forall a. Resource a => ([a] -> a) -> [a] -> Graph -> Graph
mergeResources _ [] g = g
mergeResources f xs g@Graph{..} = g
    { _grChangeLog = mkAction InsertMany insertValuesMap
                  . updateChangeLog (DeleteKeys $ map (GL.encodeUniversalResource . Res) xs)
                  . mkAction DeleteValues deleteValuesMap
                  $ _grChangeLog
    , _grGraph = mkAdjustements insertNodes insertValuesMap
              . mkAdjustements removeNodes deleteValuesMap
              $ _grGraph
    }
  where
    -- new node that is a combination of the other nodes.
    newX = f xs
    -- Gather all old relations from nodes that will be merged.
    oldRels = foldl' S.union S.empty
            . mapMaybe (\r -> M.lookup (Res r) _grGraph)
            $ xs
    -- New relations that should be inserted, we update local end in all
    -- old relations.
    newRels = S.filter doesNotMakeSelfLink
            $ S.map (updateLocalEnd newX) oldRels
    deleteValuesMap, insertValuesMap :: M.HashMap Res (S.HashSet Rel)
    deleteValuesMap = M.unionWith (<>) (M.fromList [(Res x, S.empty) | x <- xs])
                                       (mkUpdateMap oldRels)
    insertValuesMap = M.unionWith (<>) (M.singleton (Res newX) S.empty)
                                       (mkUpdateMap newRels)
    -- Helpers:
    -- Create a map that keeps updates in form.
    mkUpdateMap :: HashSet Rel -> M.HashMap Res (S.HashSet Rel)
    mkUpdateMap = M.fromListWith (<>)
       . concatMap (\r -> case r of
           InRel  _ a b -> [ (Res a, S.singleton $ GL.invert r)
                           , (Res b, S.singleton r)]
           OutRel _ a b -> [ (Res a, S.singleton r)
                           , (Res b, S.singleton $ GL.invert r)]
           )
       . S.toList
    -- Create update changelog action based on the update map.
    mkAction action = updateChangeLog . action
      . fmap (\(k,vs) -> ( GL.encodeUniversalResource k
                          , map GL.encodeUniversalRelation $ S.toList vs))
      . M.toList
    -- Update local end in the relation.
    updateLocalEnd :: forall q. Resource q => q -> Rel -> Rel
    updateLocalEnd y' rel@(InRel r x (_::b)) = case eqT :: Maybe (q :~: b) of
      Just Refl -> InRel r x y'
      Nothing -> rel
    updateLocalEnd x' rel@(OutRel r (_::b) y) = case eqT :: Maybe (q :~: b) of
      Just Refl -> OutRel r x' y
      Nothing -> rel
    -- If we don't want self links in result graph.
    doesNotMakeSelfLink :: Rel -> Bool
    doesNotMakeSelfLink (InRel  _ y _) = Res y `notElem` (Res newX:map Res xs)
    doesNotMakeSelfLink (OutRel _ _ y) = Res y `notElem` (Res newX:map Res xs)
    -- Create action that run on a graph and update that.
    mkAdjustements action m z = foldl' (\g' (k,v) -> alter (action v) k g') z $ M.toList m
    removeNodes _ Nothing = Nothing
    removeNodes v (Just w) = case S.difference w v of
                                      z | S.null z -> Nothing
                                        | otherwise -> Just z
    insertNodes v w = Just (v <> fromMaybe mempty w)
    alter fz k m =
      case fz (M.lookup k m) of
        Nothing -> M.delete k m
        Just v  -> M.insert k v m
    {-# INLINE alter #-}

-- | Fetch nodes connected through a given relation with a provided source
-- resource.
connectedTo :: forall a r b. Relation r a b
            => a -> r -> Graph -> Quantify (CardinalityTo r a b) b
connectedTo a r g =
    let rs = mapMaybe (\(Res x) -> cast x :: Maybe b) $ GL.anyConnectedTo a r g
    in case sing :: Sing (CardinalityTo r a b) of
      SAtMostOne -> listToMaybe rs
      SUnbounded -> rs
  where
    -- Get rid of unused warnings
    _ = undefined :: (SCardinality c, Proxy AtMostOneSym0, Proxy UnboundedSym0)

-- | Fetch nodes connected through a given relation with a provided
--   destination resource.
connectedFrom :: forall a r b . Relation r a b
              => r -> b -> Graph -> Quantify (CardinalityFrom r a b) a
connectedFrom r b g =
  let rs = mapMaybe (\(Res x) -> cast x :: Maybe a) $ GL.anyConnectedFrom r b g
  in case sing :: Sing (CardinalityFrom r a b) of
    SAtMostOne -> listToMaybe rs
    SUnbounded -> rs

-- | Yields the change log of modifications done to the graph, and the graph
-- with the change log removed.
takeChangeLog :: Graph -> (ChangeLog, Graph)
takeChangeLog g = ( _grChangeLog g
                  , g { _grChangeLog = emptyChangeLog }
                  )

-- | Creates a graph from key value pairs.
-- No key is duplicated in the input and no value appears twice for a given key.
buildGraph :: StoreChan -> RemoteTable -> (MetaInfo, [(Key,[Value])]) -> Graph
buildGraph mmchan rt (mi, kvs) = (\hm -> Graph mmchan emptyChangeLog hm gcInfo)
    . M.fromList
    . map ( GL.decodeUniversalResource rt *** S.fromList
          . map (GL.decodeUniversalRelation rt))
    $ kvs
  where
    gcInfo = GraphGCInfo (_miSinceGC mi)
                         (_miGCThreshold mi)
                         (map (GL.decodeUniversalResource rt) (_miRootNodes mi))

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
    updateStore (_grMMChan g) (fromChangeLog cl) cb
    return g'
  where
    shouldGC :: Graph -> Bool
    shouldGC gr = let gi = grGraphGCInfo gr
                  in grGCThreshold gi > 0 && grSinceGC gi >= grGCThreshold gi

    runGCIfThresholdMet :: Graph -> Process Graph
    runGCIfThresholdMet gr =
      if shouldGC gr then do
        let gr' = garbageCollectRoot gr
            beforeGCSize = M.size (_grGraph gr)
        seq beforeGCSize $ rgTrace $ "Garbage collecting " ++ show beforeGCSize
                                     ++ " nodes ..."
        let afterGCSize = M.size (_grGraph gr')
        seq afterGCSize $ rgTrace $ "After GC, " ++ show afterGCSize
                                    ++ " nodes remain."
        return gr'
      else return gr

-- | Retrieves the graph from the multimap store.
getGraph :: StoreChan -> Process Graph
getGraph mmchan = do
  rt <- fmap (remoteTable . processNode) ask
  buildGraph mmchan rt <$> HA.Multimap.getStoreValue mmchan

toStrict :: Lazy.ByteString -> ByteString
toStrict = Strict.concat . toChunks

getGraphResources :: Graph -> [(Res, [Rel])]
getGraphResources = fmap (second S.toList) . M.toList . _grGraph

-- | Get all resources in the graph of a particular type.
getResourcesOfType :: forall a. Resource a
                   => Graph
                   -> [a]
getResourcesOfType =
    mapMaybe (\(Res x) -> cast x :: Maybe a)
  . fst . unzip
  . getGraphResources

-- * GC control

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
    initWhite = S.fromList (M.keys _grGraph) `S.difference` initGrey
    go white (S.null -> True) = g {
        _grChangeLog = updateChangeLog
          (DeleteKeys $ map GL.encodeUniversalResource whiteList) _grChangeLog
      , _grGraph = foldl' (>>>) id adjustments _grGraph
    } where
      adjustments = map M.delete whiteList
      whiteList = S.toList white
    go white grey = go white' grey' where
      white' = white `S.difference` grey'
      grey' = white `S.intersection` S.unions (catMaybes nextGreys)

      nextGreys :: [Maybe (HashSet Res)]
      nextGreys = map (fmap (S.map f) . flip M.lookup _grGraph) (S.toList grey)

      f (OutRel _ _ y) = Res y
      f (InRel _ x _) =  Res x

-- | Runs 'garbageCollect' preserving anything connected to root nodes
-- ('getRootNodes').
garbageCollectRoot :: Graph -> Graph
garbageCollectRoot g = setSinceGC 0 $ garbageCollect (S.fromList roots) g
  where
    roots = grRootNodes $ grGraphGCInfo g


-- | Modify the 'GraphGCInfo' in the given graph.
modifyGCInfo :: (GraphGCInfo -> GraphGCInfo) -> Graph -> Graph
modifyGCInfo f g = g
  { grGraphGCInfo = newGI
  , _grChangeLog = updateChangeLog (SetMetaInfo mi) (_grChangeLog g) }
  where
    newGI = f $ grGraphGCInfo g

    mi :: MetaInfo
    mi = MetaInfo (grSinceGC newGI)
                  (grGCThreshold newGI)
                  (map GL.encodeUniversalResource $ grRootNodes newGI)

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

-- * Tools for testing

getStoreUpdates :: Graph -> [StoreUpdate]
getStoreUpdates = fromChangeLog . _grChangeLog

-- * Migration

setChangeLog :: GL.ChangeLog -> Graph -> Graph
setChangeLog cl g = g { _grChangeLog = cl }
