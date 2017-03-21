{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Frontier.Command
    ( Command(..)
    , FrontierCmd(..)
    , parseCommand
    , mmKeyValues
    , dumpGraph
    , dumpToJSON
    ) where

import           Control.Distributed.Process (ProcessId)
import           Data.Binary.Put
import qualified Data.ByteString as B
import           Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.Foldable
import           Data.Hashable
import qualified Data.Map.Strict as M
import           Data.Maybe (catMaybes)
import           Data.Typeable
import           GHC.Generics (Generic)
import qualified HA.Aeson as A
import           HA.Multimap
import           HA.ResourceGraph hiding (null)
import           HA.Services.Frontier.Interface (FrontierCmd(..))

-- | Service commands
data Command
    = CM !FrontierCmd
    -- ^ Read data from multimap
    | Quit
    -- ^ Finish work

parseCommand :: B.ByteString -> ProcessId -> Maybe Command
parseCommand "mmvalues\r" pid = Just . CM $! MultimapGetKeyValuePairs pid
parseCommand "graph\r"    pid = Just . CM $! ReadResourceGraph pid
parseCommand "jsongraph\r" pid = Just . CM $! JsonGraph pid
parseCommand "quit\r"     _   = Just Quit
parseCommand _            _   = Nothing

-- | Serialize multimap data
mmKeyValues :: Maybe ([(Key, [Value])]) -> ByteString
mmKeyValues = runPut . mmKeyValuesPut

-- | Multimap data serialiser
mmKeyValuesPut :: Maybe ([(Key, [Value])]) -> Put
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

data ResourceJson = ResourceJson
  { resource_type :: String
  , resources :: [A.Value]
  } deriving (Show, Eq, Generic)

instance A.ToJSON ResourceJson

-- | Serialise graph resources through JSON.
dumpToJSON :: [(Res, [Rel])] -> ByteString
dumpToJSON graph = A.encode jsonResources
  where
    -- Group resources by their TypeRep, this allows us better
    -- indexing if we know what we're looking for.
    --
    -- Caveat: show of typereps is not unique so once we serialise we
    -- can have multiple groups with same such as @Process@.
    jsonResources :: [ResourceJson]
    jsonResources = -- Unwrap to ResourceJson keeping groups of
                    -- different TypeReps distinct
                    map (\(r, vs) -> ResourceJson { resource_type = r
                                                  , resources =  vs }) $
                    M.toList $
                    M.mapKeysWith (++) show $
                    -- Collapse to TypeRep:[Value]
                    M.fromListWith (++) $
                    -- Every resource to TypeRep:Value
                    map (\(Res x, _) -> (typeOf x, [A.toJSON x])) graph

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
