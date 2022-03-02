{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
-- |
-- Module    : HA.RecoveryCoordinator.RC.Actions.Info
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.RC.Actions.Info
  ( mmKeyValues
  , dumpGraph
  , dumpToJSON
  ) where

import           Data.Binary.Put
import           Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.Either (partitionEithers)
import           Data.Foldable
import           Data.Hashable
import qualified Data.Map.Strict as M
import           Data.Maybe (catMaybes)
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics (Generic)
import qualified HA.Aeson as A
import           HA.Multimap
import           HA.ResourceGraph hiding (null)

-- | Serialize multimap data
mmKeyValues :: Maybe [(Key, [Value])] -> ByteString
mmKeyValues = runPut . mmKeyValuesPut

-- | Multimap data serialiser
mmKeyValuesPut :: Maybe [(Key, [Value])] -> Put
mmKeyValuesPut = traverse_ (traverse_ go)
  where
    go (key, vals) = do
        putWord8 0x28 -- (
        putByteString key
        putWord8 0x3a -- :
        mmValuesPut vals
        putWord8 0x29 -- )

-- | Serialiser for multimap 'Value's only.
mmValuesPut :: [Value] -> Put
mmValuesPut xs = do
    putWord8 0x5b -- [
    _ <- foldlM go True xs
    putWord8 0x5d -- ]
  where
    go True val = do
        putByteString val
        return False
    go x val = do
        putWord8 0x2c -- ,
        putByteString val
        return x

-- | Serialise graph structure.
dumpGraph :: [(Res, [Rel])] -> ByteString
dumpGraph graph = let
    header = "digraph rg {\n"
    footer = "}"
    (nodes, edges) = foldl' go ([], []) graph where
      go (nodes', edges') (res, rels) = let
          n = renderNode res
          e = catMaybes $ fmap renderEdge rels
        in (n : nodes', e ++ edges')
  in header `LB.append` (LB.pack $ unlines nodes)
            `LB.append` (LB.pack $ unlines edges)
            `LB.append` footer

data Named a = Named { name :: !T.Text
                     , val :: !a }

-- | 'IntJS' values get serialized to JSON as strings.
--
-- JavaScript runtimes (JS engines of web browsers, `jq` utility) cannot
-- handle integer values larger than 2^53.
-- See https://tc39.github.io/ecma262/#sec-ecmascript-language-types-number-type
--
-- E.g., `jq` "rounds" 9007199254740993 (2^53 + 1) to 9007199254740992:
--
--     $ python -c 'print(repr([2**53, 2**53 + 1]))'
--     [9007199254740992, 9007199254740993]
--     $ python -c 'print(repr([2**53, 2**53 + 1]))' | jq .
--     [
--       9007199254740992,
--       9007199254740992
--     ]
--
-- We use 'IntJS' as a workaround for this limitation.
newtype IntJS = IntJS Int
  deriving (Eq, Ord, Show)

instance A.ToJSON IntJS where
  toJSON (IntJS n) = A.String . T.pack $ show n

data Connection = Connection
  { conn_relation_id :: !IntJS
  , conn_target_resource :: !IntJS
  } deriving (Eq, Show, Generic)
instance A.ToJSON Connection

data ResourceJson = ResourceJson
  { resource_type :: !T.Text
  , resource_value :: !A.Value
  , resource_id :: !IntJS
  , relations_out :: ![Connection]
  , relations_in :: ![Connection]
  } deriving (Eq, Show, Generic)
instance A.ToJSON ResourceJson

data RelationJson = RelationJson
  { relation_type :: !T.Text
  , relation_id :: !IntJS
  } deriving (Eq, Show, Generic)
instance A.ToJSON RelationJson

data JsonGraph a = JsonGraph
  { resources :: ![ResourceJson]
  , relations :: a
  } deriving (Eq, Show, Generic, Functor)
instance A.ToJSON a => A.ToJSON (JsonGraph a)

-- | We only need to store one relation that we see for so fold into
-- the map.
type RelMap = M.Map IntJS T.Text

-- | Output resource graph as JSON. All relations are contained within
-- the resources.
dumpToJSON :: [(Res, [Rel])] -> ByteString
dumpToJSON graph = A.encode jsonGraph
  where
    jsonGraph :: JsonGraph [RelationJson]
    jsonGraph = flattenRelations <$>
      foldl' resToJson (JsonGraph [] M.empty) graph

    flattenRelations :: RelMap -> [RelationJson]
    flattenRelations = map (uncurry mkRel) . M.toList
      where
        mkRel i t = RelationJson { relation_type = t, relation_id = i }

    toConnection :: Rel -> Either (Named Connection) (Named Connection)
    toConnection (InRel r a _) = Left $! mkConnection r a
    toConnection (OutRel r _ b) = Right $! mkConnection r b

    toId :: (Hashable a, Typeable a) => a -> IntJS
    toId x = IntJS $ hash (typeOf x, x)

    mkConnection :: (Typeable a, Hashable a, Typeable b, Hashable b)
                 => a -> b -> Named Connection
    mkConnection rel res = Named
      { val = Connection { conn_relation_id = toId rel
                         , conn_target_resource = toId res
                         }
      , name = T.pack . show $ typeOf rel
      }

    resToJson :: JsonGraph RelMap -> (Res, [Rel]) -> JsonGraph RelMap
    resToJson jgraph (Res x, rels) =
      let (ins, outs) = partitionEithers $ map toConnection rels
          nToMap = M.fromList . map (\n -> (conn_relation_id $! val n, name n))
          !resJson = ResourceJson
            { resource_type = T.pack . show $ typeOf x
            , resource_value = A.toJSON x
            , resource_id = toId x
            , relations_out = val <$> outs
            , relations_in = val <$> ins
            }
      in jgraph { resources = resJson : resources jgraph
                , relations = M.unions [ relations jgraph
                                       , nToMap ins
                                       , nToMap outs
                                       ]
                }

renderNode :: Res -> String
renderNode (Res res) = mkId res
                     ++ " [label=\"" ++ (escapeQuote . show $ res) ++ "\"]"

renderEdge :: Rel -> Maybe String
renderEdge (OutRel r a b) = Just $ mkId a ++ " -> " ++ mkId b
                          ++ " [label=\"" ++ (escapeQuote . show $ r) ++ "\"]"
renderEdge _ = Nothing

escapeQuote :: String -> String
escapeQuote = map (\a -> if a == '"' then '\'' else a)

mkId :: (Hashable a, Typeable a) => a -> String
mkId a = str
  where
    hashCode = hash (typeOf a, a)
    str = if hashCode < 0
          then "n" ++ (show $ abs hashCode)
          else show hashCode
