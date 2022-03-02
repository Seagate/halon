{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Generic graph interface.
module HA.ResourceGraph.GraphLike
  ( -- * Changelog
    ChangeLog (..)
  , updateChangeLog
  , fromChangeLog
  , emptyChangeLog
    -- * GraphLike
  , Any(..)
  , Direction(..)
  , Edge(..)
  , DirectedEdge(..)
  , GraphLike(..)
    -- * Querying the graph
  , null
  , memberResource
  , memberEdge
  , memberEdgeBack
  , edgesFromSrc
  , edgesToDst
  , anyConnectedFrom
  , anyConnectedTo
  , isConnected
    -- * Modifying the graph
  , deleteEdge
  , disconnect
  , disconnectAllTo
  , disconnectAllFrom
  , removeResource
  , connectUnique
  , connectUniqueFrom
  , connectUniqueTo
  , connectUnbounded
    -- * Helpers
  , AnySafeCopyDict(..)
  , decodeAnyResource
  , AnySafeCopyDict3(..)
  , decodeAnyRelation
  , toKeyValue
  )
  where

import Control.Arrow ((***))
import Control.Distributed.Static
  ( RemoteTable
  , unstatic
  , staticLabel
  )
import Control.Lens (Lens', (^.), over)
import Data.Binary
import Data.Binary.Get (runGetOrFail)
import Data.ByteString ( ByteString )
import Data.ByteString.Lazy ( fromStrict )
import Data.Constraint ( Dict(..) )
import Data.Hashable (Hashable)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as M
import Data.HashSet (HashSet)
import qualified Data.HashSet as S
import Data.List (foldl')
import Data.Proxy (Proxy(..))
import Data.Maybe (isJust, mapMaybe, maybeToList)
import Data.Serialize.Get (runGetLazy)
import Data.Typeable (Typeable, cast)
import Data.UUID (UUID)
import Data.Word (Word8)
import GHC.Exts (Constraint, IsList(..))
import HA.Multimap
  ( Key, Value, MetaInfo, StoreChan, StoreUpdate(..) )
import HA.Multimap.Implementation
import HA.SafeCopy

import Prelude hiding (null)

--------------------------------------------------------------------------------
-- * ChangeLog
--------------------------------------------------------------------------------

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
    [ InsertMany   $ HA.Multimap.Implementation.toList is
    , DeleteValues $ HA.Multimap.Implementation.toList dvs
    , DeleteKeys   $ S.toList dks
    ] ++ maybeToList (SetMetaInfo <$> mi)

-- | An empty changelog
emptyChangeLog :: ChangeLog
emptyChangeLog = ChangeLog empty empty S.empty Nothing

--------------------------------------------------------------------------------
-- * Core GraphLike abstraction
--------------------------------------------------------------------------------

-- | Hack to allow defering resolution of the 'relation'.
data Any = forall a. Typeable a => Any !a

-- | Edges between resources. Edge types are called relations. An edge is an
-- element of some relation. The order of the fields matches that of
-- subject-verb-object triples in RDF.
data Edge a r b =
    Edge { edgeSrc      :: !a
         , edgeRelation :: !r
         , edgeDst      :: !b }
  deriving Eq

data Direction = In | Out
  deriving (Eq, Show)

-- | Encoding of directed relationship.
class DirectedEdge a where
  direction :: a -> Direction
  -- | Predicate to select 'in' edges.
  isIn :: a -> Bool
  isIn = (== In) . direction
  -- | Predicate to select 'out' edges.
  isOut :: a -> Bool
  isOut = (== Out) . direction
  -- | Invert a relation.
  invert :: a -> a

class ( DirectedEdge (UniversalRelation g)
      , Eq (UniversalResource g)
      , Hashable (UniversalResource g)
      , Eq (UniversalRelation g)
      , Hashable (UniversalRelation g)
      , Typeable (Resource g)
      , Typeable (Relation g)
      )
      => GraphLike g where
  type InsertableRes g :: * -> Constraint
  type InsertableRel g :: * -> * -> * -> Constraint

  type Resource g :: * -> Constraint
  type Relation g :: * -> * -> * -> Constraint

  type UniversalResource g = (ur :: *) | ur -> g
  type UniversalRelation g = (ur :: *) | ur -> g

  encodeUniversalResource :: UniversalResource g
                          -> ByteString
  encodeUniversalRelation :: UniversalRelation g
                          -> ByteString
  decodeUniversalResource :: RemoteTable
                          -> ByteString
                          -> UniversalResource g
  decodeUniversalRelation :: RemoteTable
                          -> ByteString
                          -> UniversalRelation g

  decodeRes :: Resource g a => UniversalResource g -> Maybe a
  encodeIRes :: InsertableRes g a => a -> UniversalResource g

  decodeRel :: Relation g r a b => UniversalRelation g -> Maybe (Edge a r b)
  encodeIRelIn :: InsertableRel g r a b => Edge a r b -> UniversalRelation g
  encodeIRelOut :: InsertableRel g r a b => Edge a r b -> UniversalRelation g

  -- | Explode a relation into its constituent parts without decoding.
  explodeRel :: UniversalRelation g
             -> (UniversalResource g, Any, UniversalResource g)

  -- | Test whether a resource exists in the graph
  queryRes :: Resource g a => a -> g -> Maybe (UniversalResource g)
  -- | Fetch relations attached to a given resource. This method may be
  --   overwritten for optimisation purposes.
  lookupRes :: Resource g a => a -> g -> HashSet (UniversalRelation g)
  lookupRes a g = maybe S.empty id $ flip M.lookup (g ^. graph) =<< queryRes a g
  -- | Test whether a relation exists in a given HashSet
  queryRel :: Relation g r a b
           => Edge a r b
           -> Direction
           -> HashSet (UniversalRelation g)
           -> Maybe (UniversalRelation g)

  -- | Increment the GC threshold if necessary.
  incrementGC :: g -> g
  incrementGC = id

  graph :: Lens' g (HashMap (UniversalResource g) (HashSet (UniversalRelation g)))

  storeChan :: Lens' g StoreChan

  changeLog :: Lens' g ChangeLog

--------------------------------------------------------------------------------
-- * Querying the graph
--------------------------------------------------------------------------------

-- | Returns @True@ iff the graph is empty, with the exception of
-- 'GraphGCInfo' resources which are filtered out before making the
-- check.
null :: GraphLike g => g -> Bool
null g = M.null $ g ^. graph

-- | Tests whether a given resource is a vertex in a given graph.
memberResource :: (GraphLike g, Resource g a)
               => a -> g -> Bool
memberResource a g = isJust $ queryRes a g

-- | Test whether two resources are connected through the given relation.
memberEdge :: forall g r a b. (GraphLike g, Resource g a, Relation g r a b)
           => Edge a r b -> g -> Bool
memberEdge e g =
  isJust . queryRel e Out . S.filter isOut $ lookupRes (edgeSrc e) g

-- | Test whether two resources are connected through the given relation.
--   Compared to 'memberEdge', looks up the relation from the remote endpoint.
--   This is mostly useful for testing, since 'memberEdge' and 'memgerEdgeBack'
--   should give identical results all of the time.
memberEdgeBack :: forall g a r b. (GraphLike g, Resource g b, Relation g r a b)
               => Edge a r b -> g -> Bool
memberEdgeBack e g =
  isJust . queryRel e In . S.filter isIn $ lookupRes (edgeDst e) g

-- | More convenient version of 'memberEdge'.
isConnected :: (GraphLike g, Relation g r a b, Resource g a)
            => a -> r -> b -> g -> Bool
isConnected x r y g = memberEdge (Edge x r y) g

-- | List of all edges of a given relation stemming from the provided source
-- resource to destination resources of the given type.
edgesFromSrc :: (GraphLike g, Resource g a, Relation g r a b)
             => a -> g -> [Edge a r b]
edgesFromSrc x0 g =
  mapMaybe decodeRel $ S.toList . S.filter isOut $ lookupRes x0 g

-- | List of all edges of a given relation incoming at the provided destination
-- resource from source resources of the given type.
edgesToDst :: (GraphLike g, Resource g b, Relation g r a b)
           => b -> g -> [Edge a r b]
edgesToDst x0 g =
  mapMaybe decodeRel $ S.toList . S.filter isIn $ lookupRes x0 g

-- | List of all nodes connected through a given relation with a provided source
-- resource.
anyConnectedTo :: forall g r a.
                  ( GraphLike g, Resource g a, Typeable r )
               => a -> r -> g -> [UniversalResource g]
anyConnectedTo x0 _ g =
  let f (explodeRel -> (_, Any r, b)) = Just b <* (cast r :: Maybe r)
  in mapMaybe f . S.toList . S.filter isOut $ lookupRes x0 g

-- | List of all nodes connected through a given relation with a provided
--   destination resource.
anyConnectedFrom :: forall g r b.
                    (GraphLike g, Resource g b, Typeable r)
                 => r -> b -> g -> [UniversalResource g]
anyConnectedFrom _ x0 g =
  let f (explodeRel -> (a, Any r, _)) = Just a <* (cast r :: Maybe r)
  in mapMaybe f . S.toList . S.filter isIn $ lookupRes x0 g

--------------------------------------------------------------------------------
-- * Modifying the graph
--------------------------------------------------------------------------------

-- | Delete an edge from the graph.
deleteEdge :: ( GraphLike g
              , Resource g a
              , Resource g b
              , Relation g r a b
              )
           => Edge a r b -> g -> g
deleteEdge e@Edge{..} g = incrementGC $ maybe g
  ( \(src, rel, dest) ->
      over changeLog
      ( updateChangeLog $
          DeleteValues
            [ ( encodeUniversalResource src
              , [ encodeUniversalRelation rel ])
            , ( encodeUniversalResource dest
              , [ encodeUniversalRelation $ invert rel ])
            ]
      )
    . over graph
      ( M.adjust (S.delete rel) src
      . M.adjust (S.delete $ invert rel) dest
      )
    $ g
  ) mrel
  where
    mrel = (,,) <$> (queryRes edgeSrc g)
               <*> (queryRel e Out . S.filter isOut $ lookupRes edgeSrc g)
               <*> (queryRes edgeDst g)

-- | Removes a relation.
disconnect :: ( GraphLike g
              , Resource g a
              , Resource g b
              , Relation g r a b
              )
           => a -> r -> b -> g -> g
disconnect x r y g = deleteEdge (Edge x r y) g

-- | Remove all outgoing edges of the given relation type.
disconnectAllFrom :: forall g a r b.
                      ( GraphLike g
                      , Resource g a
                      , Resource g b
                      , Relation g r a b
                      )
                  => a -> r -> Proxy b -> g -> g
disconnectAllFrom a _ _ g = foldl' (.) id (fmap deleteEdge oldEdges) $ g
  where
    oldEdges = edgesFromSrc a g :: [Edge a r b]

-- | Remove all incoming edges of the given relation type.
disconnectAllTo :: forall g a r b.
                    ( GraphLike g
                    , Resource g a
                    , Resource g b
                    , Relation g r a b
                    )
                => Proxy a -> r -> b -> g -> g
disconnectAllTo _ _ b g = foldl' (.) id (fmap deleteEdge oldEdges) $ g
  where
    oldEdges = edgesToDst b g :: [Edge a r b]


-- | Isolate a resource from the rest of the graph. This removes
--   all relations from the node, regardless of type.
removeResource :: forall g a. (GraphLike g, Resource g a) => a -> g -> g
removeResource r g = maybe g
    (\res ->
      over graph
        ( M.delete res
        . foldl' (.) id (fmap unhookG rels)
        )
    . over changeLog
        ( updateChangeLog ( DeleteKeys [euRes res] )
        . updateChangeLog ( DeleteValues (fmap unhookCL rels))
        )
    $ g
    ) mres
  where
    euRes :: UniversalResource g -> ByteString
    euRes = encodeUniversalResource
    euRel :: UniversalRelation g -> ByteString
    euRel = encodeUniversalRelation

    mres = queryRes r g
    rels = S.toList $ lookupRes r g

    unhookCL rel | isIn rel =
      let (x, _, _) = explodeRel rel
      in (euRes x, [ euRel (invert rel) ])
    unhookCL rel =
      let (_, _, y) = explodeRel rel
      in (euRes y, [ euRel (invert rel) ])
    unhookG rel | isIn rel =
      let (x, _, _) = explodeRel rel
      in M.adjust (S.delete (invert rel)) x
    unhookG rel =
      let (_, _, y) = explodeRel rel
      in M.adjust (S.delete (invert rel)) y

-- | Adds a relation without making a conversion from 'Edge'.
--
-- Unlike 'connect', it doesn't check cardinalities.
connectUnbounded :: forall g r a b.
                    ( GraphLike g
                    , InsertableRes g a
                    , InsertableRes g b
                    , InsertableRel g r a b
                    )
                 => a -> r -> b -> g -> g
connectUnbounded x r y g =
      over changeLog
        (updateChangeLog $
             InsertMany [ (eRes x,[ eRelO x r y ])
                        , (eRes y,[ eRelI x r y ])
                        ]
        )
    . over graph
        ( M.insertWith S.union (encodeIRes x) (S.singleton $ outRel x r y)
        . M.insertWith S.union (encodeIRes y) (S.singleton $ inRel x r y)
        )
    $ g
  where
    euRes :: UniversalResource g -> ByteString
    euRes = encodeUniversalResource
    euRel :: UniversalRelation g -> ByteString
    euRel = encodeUniversalRelation
    eRes :: forall res. InsertableRes g res => res -> ByteString
    eRes = euRes . encodeIRes
    eRelI a r' b = euRel $ inRel a r' b
    eRelO a r' b = euRel $ outRel a r' b
    outRel a r' b = encodeIRelOut $ Edge a r' b
    inRel a r' b = encodeIRelIn $ Edge a r' b

-- | Connect uniquely between two given resources - e.g. make this relation
--   uniquely determining from either side.
connectUnique :: forall g r a b.
                    ( GraphLike g
                    , InsertableRes g a
                    , InsertableRes g b
                    , InsertableRel g r a b
                    , Resource g a
                    , Resource g b
                    , Relation g r a b
                    )
              => a -> r -> b -> g -> g
connectUnique x r y = connectUnbounded x r y
                    . disconnectAllFrom x r (Proxy :: Proxy b)
                    . disconnectAllTo (Proxy :: Proxy a) r y

-- | Connect uniquely from a given resource - e.g. remove all existing outgoing
--   edges of the same type first.
connectUniqueFrom :: forall g r a b.
                    ( GraphLike g
                    , InsertableRes g a
                    , InsertableRes g b
                    , InsertableRel g r a b
                    , Resource g a
                    , Resource g b
                    , Relation g r a b
                    )
                  => a -> r -> b -> g -> g
connectUniqueFrom x r y = connectUnbounded x r y
                        . disconnectAllFrom x r (Proxy :: Proxy b)

-- | Connect uniquely to a given resource - e.g. remove all existing incoming
--   edges of the same type first.
connectUniqueTo :: forall g r a b.
                    ( GraphLike g
                    , InsertableRes g a
                    , InsertableRes g b
                    , InsertableRel g r a b
                    , Resource g a
                    , Resource g b
                    , Relation g r a b
                    )
                => a -> r -> b -> g -> g
connectUniqueTo x r y = connectUnbounded x r y
                      . disconnectAllTo (Proxy :: Proxy a) r y

data AnySafeCopyDict (c :: * -> Constraint) = forall a . SafeCopy a => A (Dict (c a))

-- | Decode resource from wire message.
decodeAnyResource :: forall p t f . Typeable f
                  => Proxy (p :: * -> Constraint) -- ^ Describe the constraints we want to get.
                  -> (f -> AnySafeCopyDict p) -- ^ Function that wraps wire message to dict carry message.
                  -> (UUID -> String) -- ^ Converted from UUID to the label in static table.
                  -> (forall a . p a => a -> t) -- ^ Converter that create requrired value.
                  -> RemoteTable
                  -> ByteString                 -- ^ Wire message.
                  -> t
decodeAnyResource _p rewrap mkResKeyName create rt bs =
    case runGetOrFail get $ fromStrict bs of
      Right (rest,_,d)
       | d == staticLabel "" -> new rest
       | otherwise -> old rest d
      Left (_,_,err) -> error $ "decodeRes: " ++ err
    where
      new rest0 = case runGetOrFail get rest0 of
        Right (rest,_,uuid) ->
           case fmap rewrap (unstatic rt (staticLabel $ mkResKeyName uuid)) of
             Right (A (Dict :: Dict (p s))) ->
               case runGetLazy safeGet rest of
                 Right r -> create (r :: s)
                 Left err -> error $ "decodeRes: runGetLazy: " ++ show err
             Left err -> error $ "decodeRes: " ++ err
        _ -> error $ "decodeRes: can't decode."
      old rest d = case fmap rewrap (unstatic rt d) of
        Right (A (Dict :: Dict (p s))) ->
          case runGetLazy safeGet rest of
            Right r -> create (r :: s)
            Left err -> error $ "decodeRes: runGetLazy: " ++ err
        Left err -> error $ "decodeRes: " ++ err


data AnySafeCopyDict3 (c :: * -> * -> * -> Constraint) = forall r a b .
   (SafeCopy r, SafeCopy a, SafeCopy b) => A3 (Dict (c r a b))

-- | Decode relation from wire message
decodeAnyRelation :: forall p t f . Typeable f
   => Proxy (p :: * -> * -> * -> Constraint) -- ^ Proxy that carry constraints that we wish to attach
   -> (f -> AnySafeCopyDict3 p) -- ^ A way to convert generic message to the messag that carry constraints.
   -> (UUID -> UUID -> UUID -> String) -- ^ Function to create resource label
   -> (forall r a b . p r a b => r -> a -> b -> t) -- ^ Function to create In relation
   -> (forall r a b . p r a b => r -> a -> b -> t) -- ^ Function to create Out relation
   -> RemoteTable
   -> ByteString                                   -- ^ Wire message
   -> t
decodeAnyRelation _p rewrap genName createIn createOut rt bs = case runGetOrFail get $ fromStrict bs of
    Right (rest,_,d)
      | d == staticLabel "" -> new rest
      | otherwise -> old rest d
    Left (_,_,err) -> error $ "decodeRel: " ++ err
    where
      new rest0 = case runGetOrFail get rest0 of
        Right (rest,_,(ur,ua,ub)) ->
           case fmap rewrap (unstatic rt (staticLabel $ genName ur ua ub)) of
             Right (A3 (Dict :: Dict (p r a b))) ->
               case runGetLazy safeGet rest :: Either String (Word8, r, a, b) of
                 Right (b, r, x, y) -> case b of
                   0 -> createIn r x y
                   1 -> createOut r x y
                   _ -> error $ "decodeRel: Invalid direction bit."
                 Left err -> error $ "decodeRes: runGetLazy: " ++ show err
             Left err -> error $ "decodeRes: " ++ err
        _ -> error $ "decodeRes: can't decode."
      old rest d = case fmap rewrap (unstatic rt d) of
        Right (A3 (Dict :: Dict (p r a b))) ->
          case runGetLazy safeGet rest :: Either String (Word8, r, a, b) of
            Right (b, r, x, y) -> case b of
              (0 :: Word8) -> createIn r x y
              (1 :: Word8) -> createOut r x y
              _ -> error $ "decodeRel: Invalid direction bit."
            Left err -> error $ "decodeRel: runGetLazy: " ++ err
        Left err -> error $ "decodeRel: " ++ err

-- | Encode full graph into @[('Key', ['Value'])]@ format. Useful as a
-- middle-ground for 'GraphLike' conversions.
toKeyValue
  :: forall g l.
     ( GraphLike g
     , IsList (l (UniversalResource g) (HashSet (UniversalRelation g)))
     , Item (l (UniversalResource g) (HashSet (UniversalRelation g)))
       ~ (UniversalResource g, HashSet (UniversalRelation g)))
  => l (UniversalResource g) (HashSet (UniversalRelation g))
  -> [(Key, [Value])]
toKeyValue = map (encRes *** encRels) . GHC.Exts.toList
  where
    encRes :: UniversalResource g -> Key
    encRes = encodeUniversalResource
    encRels :: HashSet (UniversalRelation g) -> [Value]
    encRels = map encodeUniversalRelation . S.toList
