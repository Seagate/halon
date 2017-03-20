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
    ) where

import qualified Data.ByteString as B
import           Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.Foldable

import Data.Binary.Put
import Data.Hashable
import Data.Maybe (catMaybes)
import Data.Typeable (Typeable, typeOf)

import Control.Distributed.Process (ProcessId)
import HA.Multimap
import HA.ResourceGraph hiding (null)
import HA.Services.Frontier.Interface (FrontierCmd(..))

-- | Service commands
data Command
    = CM !FrontierCmd
    -- ^ Read data from multimap
    | Quit
    -- ^ Finish work

parseCommand :: B.ByteString -> ProcessId -> Maybe Command
parseCommand "mmvalues\r" pid = Just . CM $! MultimapGetKeyValuePairs pid
parseCommand "graph\r"    pid = Just . CM $! ReadResourceGraph pid
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
