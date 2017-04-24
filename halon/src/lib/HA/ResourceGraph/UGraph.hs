{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE InstanceSigs #-}
-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Unrestricted graph interface.
module HA.ResourceGraph.UGraph
  ( UGraph
  , buildUGraph
    -- * Modification
  , connect
    -- * Queries
  , connectedFrom
  , connectedTo
  , GL.null
  , GL.memberResource
  , GL.memberEdge
  , GL.memberEdgeBack
  , GL.edgesFromSrc
  , GL.edgesToDst
  , GL.isConnected
  , GL.disconnect
  , GL.disconnectAllFrom
  , GL.disconnectAllTo
  , GL.removeResource
  , grUGraphGCInfo
    -- * Migration
  , getChangeLog
  , getGraphValues
  ) where

import Control.Distributed.Static
  ( RemoteTable
  , Static
  , staticLabel
  )
import Control.Lens
import Data.Binary
import Data.ByteString.Lazy (toStrict)
import Data.Constraint ( Dict(..) )
import Data.Either (partitionEithers)
import Data.Foldable (foldl')
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as M
import Data.HashSet (HashSet)
import qualified Data.HashSet as S
import Data.Hashable
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Proxy
import qualified Data.Sequence as Seq
import Data.Serialize.Put (runPutLazy)
import qualified Data.Text as T
import Data.Typeable
import Data.Word (Word8)
import HA.Multimap
  ( Key
  , Value
  , MetaInfo(..)
  , StoreChan
  , StoreUpdate(..)
  )
import HA.ResourceGraph
  ( GraphGCInfo(..)
  , StorageRelation(..)
  , StorageResource(..)
  , SomeStorageResourceDict(..)
  , SomeStorageRelationDict(..)
  , SomeResourceDict(..)
  , SomeRelationDict(..)
  , Resource(..)
  , Relation(..)
  , genStorageResourceKeyName
  , genStorageRelationKeyName
  , StorageIndex(..)
  )
import HA.ResourceGraph.GraphLike (Edge(..), emptyChangeLog)
import qualified HA.ResourceGraph.GraphLike as GL
import HA.SafeCopy

import Prelude hiding (null)

data UGraph = UGraph
   { _grUMMChan :: StoreChan
   , _grUChangeLog :: !GL.ChangeLog
   , _grUGraph :: HashMap URes (HashSet URel)
   , _grUGraphGCInfo :: GraphGCInfo
   } deriving (Typeable)

data URes = forall a . StorageResource a => URes !a

deriving instance Show URes

instance Eq URes where
  URes a == URes b = fromMaybe False ((a ==) <$> cast b)

instance Hashable URes where
  hashWithSalt s (URes x) = s `hashWithSalt` (typeOf x, x)

data URel = forall r a b . StorageRelation r a b => InURel !r a b
          | forall r a b . StorageRelation r a b => OutURel !r a b
deriving instance Show URel

instance Eq URel where
  (InURel r a b) == (InURel r1 a1 b1) = maybe False and $ sequence
        [ (r ==) <$> cast r1, (a ==) <$> cast a1, (b ==) <$> cast b1]
  (OutURel r a b) == (OutURel r1 a1 b1) = maybe False and $ sequence
        [ (r ==) <$> cast r1, (a ==) <$> cast a1, (b ==) <$> cast b1]
  _ == _ = False

instance Hashable URel where
  hashWithSalt s (InURel r a b) =
     s `hashWithSalt` (0 :: Int) `hashWithSalt` (typeOf r, r)
       `hashWithSalt` (typeOf a, a) `hashWithSalt` (typeOf b, b)
  hashWithSalt s (OutURel r a b) =
     s `hashWithSalt` (1 :: Int) `hashWithSalt` (typeOf r, r)
       `hashWithSalt` (typeOf a, a) `hashWithSalt` (typeOf b, b)


instance GL.DirectedEdge URel where
  direction InURel{} = GL.In
  direction OutURel{} = GL.Out
  invert (InURel r a b) = OutURel r a b
  invert (OutURel r a b) = InURel r a b

makeLenses ''UGraph

-- | Create a proxy out of value.
proxy :: r -> Proxy r
proxy _ = Proxy

instance GL.GraphLike UGraph where
  type InsertableRes UGraph = Resource
  type InsertableRel UGraph = Relation

  type Resource UGraph = StorageResource
  type Relation UGraph = StorageRelation

  type UniversalResource UGraph = URes
  type UniversalRelation UGraph = URel

  encodeUniversalResource (URes (r :: r)) = toStrict $
    encode (staticLabel "" :: Static SomeResourceDict)
    <> encode (typeKey (Proxy :: Proxy r))
    <> runPutLazy (safePut r)

  encodeUniversalRelation (InURel (r :: r) (x :: a) (y :: b)) = toStrict $
    encode (staticLabel "" :: Static SomeRelationDict)
    <> encode ( typeKey (proxy r)
              , typeKey (proxy x)
              , typeKey (proxy y))
    <> runPutLazy (safePut (0 :: Word8, r, x, y))
  encodeUniversalRelation (OutURel (r :: r) (x :: a) (y :: b)) = toStrict $
    encode (staticLabel "" :: Static SomeRelationDict)
    <> encode ( typeKey (proxy r)
              , typeKey (proxy x)
              , typeKey (proxy y))
    <> runPutLazy (safePut (1 :: Word8, r, x, y))

  decodeUniversalResource = GL.decodeAnyResource
    (Proxy :: Proxy StorageResource)
    (\(SomeStorageResourceDict (Dict :: Dict (StorageResource a))) ->
      GL.A (Dict :: Dict (StorageResource a)))
    genStorageResourceKeyName
    URes

  decodeUniversalRelation = GL.decodeAnyRelation
    (Proxy :: Proxy StorageRelation)
    (\(SomeStorageRelationDict (Dict :: Dict (StorageRelation r a b))) ->
      GL.A3 (Dict :: Dict (StorageRelation r a b)))
    genStorageRelationKeyName
    InURel
    OutURel

  decodeRes :: forall a. StorageResource a => URes -> Maybe a
  decodeRes (URes a) = cast a :: Maybe a

  decodeRel :: forall r a b . StorageRelation r a b => URel -> Maybe (Edge a r b)
  decodeRel (InURel r a b)  = Edge <$> cast a <*> cast r <*> cast b
  decodeRel (OutURel r a b) = Edge <$> cast a <*> cast r <*> cast b

  encodeIRes a = URes a
  encodeIRelIn (Edge s r d) = InURel r s d
  encodeIRelOut (Edge s r d) = OutURel r s d

  -- explodeRel :: Rel -> (Res, GL.Any, Res)
  explodeRel (OutURel r s d) = (URes s, GL.Any r, URes d)
  explodeRel (InURel r s d)  = (URes s, GL.Any r, URes d)

  -- queryRes :: StorageResource a => a -> g -> Maybe URes
  queryRes a g =
    let res = URes a
    in if res `M.member` (_grUGraph g) then Just res else Nothing

  queryRel :: StorageRelation r a b => Edge a r b -> GL.Direction -> HashSet URel -> Maybe URel
  queryRel (Edge s r d) GL.In hs =
    let rel = InURel r s d
    in if rel `S.member` hs then Just rel else Nothing
  queryRel (Edge s r d) GL.Out hs =
    let rel = OutURel r s d
    in if rel `S.member` hs then Just rel else Nothing

  incrementGC = id
  graph = grUGraph
  storeChan = grUMMChan
  changeLog = grUChangeLog

connect :: forall r a b . Relation r a b => a -> r -> b -> UGraph -> UGraph
connect = GL.connectUnbounded

connectedTo :: forall r a b . StorageRelation r a b => a -> r -> UGraph -> [b]
connectedTo a _ g = map (\(Edge _ _ d :: Edge a r b) -> d) $ GL.edgesFromSrc a g

connectedFrom :: forall r a b . StorageRelation r a b =>  r -> b -> UGraph -> [a]
connectedFrom _ b g = map (\(Edge s _ _ :: Edge a r b) -> s) $ GL.edgesToDst b g

-- | Build up a 'UGraph' from the given binary information. Collects
-- any decoding errors.
buildUGraph :: StoreChan -- ^ MM
            -> RemoteTable
            -> (MetaInfo, [(Key, [Value])])
            -- ^ (Starting metainfo, graph values)
            -> (Seq.Seq T.Text, UGraph)
            -- ^ (errors, rest of graph)
buildUGraph mmchan rt (mi, kvs) =
  let (ers, m) = foldl' go (Seq.empty, M.empty) kvs
  in (ers Seq.>< rootErs, UGraph mmchan (freshLog m) m gcInfo)
  where
    go (!ers, !m) (k, vs) = case GL.decodeUniversalResource rt k of
      Left e -> (ers Seq.|> e, m)
      Right res ->
        let (es, rels) = partitionEithers $ map (GL.decodeUniversalRelation rt) vs
        in (ers Seq.>< Seq.fromList es, M.insert res (S.fromList rels) m)

    (rootErs, gcInfo) =
      let (e, rs) = partitionEithers $ map (GL.decodeUniversalResource rt) (_miRootNodes mi)
      in (Seq.fromList e, GraphGCInfo (_miSinceGC mi) (_miGCThreshold mi) rs)

    -- We're reading in a UGraph with possibly old, discarded
    -- relations. Create a changelog that completely wipes the whole
    -- graph then insert back the items we actually decoded and care
    -- about. This allows us to get rid of stale data in the MM. Note
    -- that we won't necessarily end up with a large update:
    -- 'updateChangeLog' compresses the diff so shared resources will
    -- not require an update.
    --
    -- [performance]: It would be faster to remember which resources
    -- we failed to decode and only remove those. If performance is
    -- ever a problem here, that's a cheap improvement. Another one is
    -- to not build a UGraph above at all but instead work over binary
    -- resources as in the end we have to decode it again after in
    -- constrained RG anyway as part of migration.
    freshLog m =
          -- Propose everything for deletion
      let allGone = GL.updateChangeLog (DeleteValues kvs) emptyChangeLog
          -- Get binary (MM) representation of every resource we care about.
          binaryRes = [ (key, vals)
                      | (k', vs') <- M.toList m
                      , let key = GL.encodeUniversalResource k'
                            vals = map GL.encodeUniversalRelation (S.toList vs')
                      ]
         -- Merge the two
      in GL.updateChangeLog (InsertMany binaryRes) allGone

getChangeLog :: UGraph -> GL.ChangeLog
getChangeLog = _grUChangeLog

getGraphValues :: UGraph -> HashMap URes (HashSet URel)
getGraphValues = _grUGraph
