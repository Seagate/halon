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

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}

module HA.ResourceGraph
    ( -- * Types
      Resource(..)
    , Relation(..)
    , ResourceDict(..)
    , RelationDict(..)
    , mkResourceDict
    , mkRelationDict
    , Some(..)
    , Graph
    , Edge(..)
    -- * Operations
    , newResource
    , insertEdge
    , deleteEdge
    , connect
    , disconnect
    , sync
    , getGraph
    , garbageCollect
    -- * Queries
    , null
    , memberResource
    , memberEdge
    , edgesFromSrc
    , connectedTo
    , isConnected
    ) where

import HA.Multimap
  ( Key
  , Value
  , StoreUpdate(..)
  , updateStore
  , getKeyValuePairs
  )

import Control.Distributed.Process ( ProcessId, Process )
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Process.Serializable ( Serializable )
import Control.Distributed.Static ( Static, unstatic, RemoteTable )

import Prelude hiding (null)
import Control.Arrow ( (***) )
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
import Data.Maybe
import Data.Typeable ( Typeable, cast )


-- | A type can be declared as modeling a resource by making it an instance of
-- this class.
class (Eq a, Hashable a, Serializable a) => Resource a where
  resourceDict :: a -> Static (Some ResourceDict)

-- | Hack to access methods of 'Resource' instances from 'Static' values.
data ResourceDict a where
  ResourceDict :: Resource a => ResourceDict a
 deriving Typeable

-- | Auxiliary function to implement 'relationDict'
mkResourceDict :: forall r . Resource r => r -> Some ResourceDict
mkResourceDict _ = Some (ResourceDict :: ResourceDict r)

-- | A relation on resources specifies what relationships can exist between
-- any two given types of resources. Two resources of type @a@, @b@, cannot be
-- related through @r@ if an @Relation r a b@ instance does not exist.
class (Hashable r, Serializable r, Resource a, Resource b) => Relation r a b where
  relationDict :: (r,a,b) -> Static (Some RelationDict)

-- | Hack to access methods of 'Relation' instances from 'Static' values.
data RelationDict r where
  RelationDict :: Relation r a b => RelationDict (r,a,b)
 deriving Typeable

-- | Auxiliary function to implement 'relationDict'
mkRelationDict :: forall r x y . Relation r x y => (r,x,y) -> Some RelationDict
mkRelationDict _ = Some (RelationDict :: RelationDict (r,x,y))

-- | An internal wrapper for resources to have one universal type of resources.
data Res = forall a. Resource a => Res !a

-- | Short for "relationship". A relationship in an element of a relation.
-- A relationship is synomymous to an edge. Relationships are not type indexed
-- and are internal to this module. Edges are external representations of
-- a relationship.
data Rel = forall r a b. Relation r a b => Rel !r a b

instance Hashable Res where
    hashWithSalt s (Res x) = s `hashWithSalt` x

instance Hashable Rel where
    hashWithSalt s (Rel r a b) =
        s `hashWithSalt` r `hashWithSalt` a `hashWithSalt` b

instance Eq Res where
    Res x == Res y = maybe False (x==) $ cast y

instance Eq Rel where
    Rel (_ :: r) x1 y1 == Rel r2 x2 y2
        | Just _ <- cast r2 :: Maybe r,
          Just x2' <- cast x2,
          Just y2' <- cast y2 =
          -- Don't need to compare r1, r2 for equality because they are
          -- assumed to be witnesses of singleton types, so if the type cast
          -- above works then they must be equal.
          x1 == x2' && y1 == y2'
        | otherwise = error "RHS and LHS relations don't match."

-- | The graph
data Graph = Graph { grMMId :: ProcessId  -- ^ Pid of the multimap which
                                          -- replicates the graph
                   , grChangeLog :: [StoreUpdate]
                                    -- ^ Changes in the graph with respect to
                                    -- the version stored in the multimap
                   , grGraph :: HashMap Res (HashSet Rel)
                                    -- ^ The graph
                   }

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
    fromEdge e `S.member` maybe S.empty id (M.lookup (Res (edgeSrc e)) (grGraph g))

fromEdge :: Relation r a b => Edge a r b -> Rel
fromEdge Edge{..} = Rel edgeRelation edgeSrc edgeDst

-- | Register a new resource. A resource is meant to be immutable: it does not
-- change and lives forever.
newResource :: Resource a => a -> Graph -> Graph
newResource x g =
    g { grChangeLog = InsertMany [ (encodeRes x,[]) ] : grChangeLog g
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
    g { grChangeLog =
            DeleteValues [ (encodeRes edgeSrc, [ encodeRel $ fromEdge e ]) ]
            : grChangeLog g
      , grGraph = M.adjust (S.delete $ fromEdge e) (Res edgeSrc) $ grGraph g
      }

-- | Adds a relation without making a conversion from 'Edge'.
connect :: Relation r a b => a -> r -> b -> Graph -> Graph
connect x r y g =
   g { grChangeLog =
         InsertMany [ (encodeRes x,[ encodeRel $ Rel r x y ])] : grChangeLog g
     , grGraph =
         M.insertWith S.union (Res x) (S.singleton $ Rel r x y) $ grGraph g
     }

-- | Removes a relation.
disconnect :: Relation r a b => a -> r -> b -> Graph -> Graph
disconnect x r y g =
    g { grChangeLog = DeleteValues [ (encodeRes x, [ encodeRel $ Rel r x y ]) ]
                      : grChangeLog g
      , grGraph = M.adjust (S.delete $ Rel r x y) (Res x) $ grGraph g
      }

-- | Remove all resources that are not connected to the rest of the graph,
-- starting from the given root set. This cleans up resources that are no
-- longer participating in the graph since they are not connected to the rest
-- and can hence safely be discarded.
garbageCollect :: Resource a => [a] -> Graph -> Graph
garbageCollect = undefined

-- | List of all edges of a given relation stemming from the provided source
-- resource to destination resources of the given type.
edgesFromSrc :: Relation r a b => a -> Graph -> [Edge a r b]
edgesFromSrc x0 g =
    let f (Rel r x y) = liftM3 Edge (cast x) (cast r) (cast y)
    in maybe [] (catMaybes . map f . S.toList) $ M.lookup (Res x0) $ grGraph g

-- | List of all nodes connected through a given relation with a provided source
-- resource.
connectedTo :: forall a r b . Relation r a b => a -> r -> Graph -> [b]
connectedTo x0 _ g =
    let f (Rel r _ y) = maybe Nothing (const $ cast y) (cast r :: Maybe r)
    in maybe [] (catMaybes . map f . S.toList) $ M.lookup (Res x0) $ grGraph g

-- | More convenient version of 'memberEdge'.
isConnected :: Relation r a b => a -> r -> b -> Graph -> Bool
isConnected x r y g = memberEdge (Edge x r y) g

-- | Yields the change log of modifications done to the graph, and the graph
-- with the change log removed.
takeChangeLog :: Graph -> ([StoreUpdate],Graph)
takeChangeLog g = (reverse $ grChangeLog g, g { grChangeLog = [] })

-- | Creates a graph from key value pairs.
-- No key is duplicated in the input and no value appears twice for a given key.
buildGraph :: ProcessId -> RemoteTable -> [(Key,[Value])] -> Graph
buildGraph mmpid rt = Graph mmpid []
    . M.fromList
    . map (decodeRes rt *** S.fromList . map (decodeRel rt))

-- | Updates the multimap store with the latest changes to the graph.
sync :: Graph -> Process Graph
sync g =
    updateStore (grMMId g) upds
      >>= return . maybe (error "sync: updating the multimap store") (const g')
  where
    (upds,g') = takeChangeLog g

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

-- | An auxiliary type for hiding parameters of type constructors
data Some f = forall a. Some (f a)
               deriving Typeable

-- | Encodes a Res into a 'Lazy.ByteString'.
encodeRes :: Resource r => r -> ByteString
encodeRes r = toStrict $ encode (resourceDict r) `append` encode r

-- | Decodes a Res from a 'Lazy.ByteString'.
decodeRes :: RemoteTable -> ByteString -> Res
decodeRes rt bs =
    case runGetOrFail get $ fromStrict bs of
      Right (rest,_,d) -> case unstatic rt d of
        Right (Some (ResourceDict :: ResourceDict s)) -> Res (decode rest :: s)
        Left err -> error $ "decodeRes: " ++ err
      Left (_,_,err) -> error $ "decodeRes: " ++ err

-- | Encodes a Rel into a 'Lazy.ByteString'.
encodeRel :: Rel -> ByteString
encodeRel (Rel r x y) = toStrict $ encode (relationDict (r,x,y)) `append` encode (r,x,y)

-- | Decodes a Rel from a 'Lazy.ByteString'.
decodeRel :: RemoteTable -> ByteString -> Rel
decodeRel rt bs =
    case runGetOrFail get $ fromStrict bs of
      Right (rest,_,d) -> case unstatic rt d of
        Right (Some rd@RelationDict) ->
            let (r,x,y) = extractrxy rd $ decode rest
                extractrxy :: RelationDict a -> a -> a
                extractrxy _ = id
             in Rel r x y
        Left err -> error $ "decodeRel: " ++ err
      Left (_,_,err) -> error $ "decodeRel: " ++ err
