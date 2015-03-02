{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Frontier.Command
    ( Command(..)
    , Response(..)
    , parseCommand
    , respond
    ) where

import qualified Data.ByteString as B
import           Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.Foldable

import Data.Binary.Put
import Data.Hashable
import Data.Maybe (catMaybes)

import HA.Multimap
import HA.ResourceGraph hiding (null)

data Command
    = MultimapGetKeyValuePairs
    | ReadResourceGraph
    | Quit

data Response
    = ServeMultimapKeyValues (Maybe [(Key, [Value])])
    | ServeResources [(Res, [Rel])]

parseCommand :: B.ByteString -> Maybe Command
parseCommand "mmvalues\r" = Just MultimapGetKeyValuePairs
parseCommand "graph\r"    = Just ReadResourceGraph
parseCommand "quit\r"     = Just Quit
parseCommand _            = Nothing

respond :: Response -> ByteString
respond (ServeMultimapKeyValues mxs) = mmKeyValues mxs
respond (ServeResources xs)          = dumpGraph xs

mmKeyValues :: Maybe ([(Key, [Value])]) -> ByteString
mmKeyValues = runPut . mmKeyValuesPut

mmKeyValuesPut :: Maybe ([(Key, [Value])]) -> Put
mmKeyValuesPut = traverse_ (traverse_ go)
  where
    go (key, vals) = do
        putWord8 0x28 -- (
        putByteString key
        putWord8 0x3a -- :
        mmValuesPut vals
        putWord8 0x29 -- )

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

mkId :: Hashable a => a -> String
mkId a = str
  where
    hashCode = hash a
    str = if hashCode < 0
          then "n" ++ (show $ abs hashCode)
          else show hashCode
