-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE ScopedTypeVariables #-}
module Mero.Genders (queryNodes, queryAttribute) where

import Data.Maybe
import System.Process
import System.IO
import Control.Exception (catch)

-- | Queries genders file (pointed by GENDERS environent
-- variable) for the given attribute. Will return a list
-- of host IDs (which may or may not need to be further
-- refined into actual addresses).
queryNodes :: String -> IO [String]
queryNodes arg =
  do ret <- query ["nodes",arg]
     return $ maybe [] id $ readMaybe ret

queryAttribute :: String -> String -> IO String
queryAttribute node attr =
  query ["attr",node,attr]

query :: [String] -> IO String
query args = go `catch` (\(_ :: IOError) -> return [])
  where
    go = do (_, Just out, _, proch) <- createProcess queryproc
            ret <- hGetLine out
            _ <- waitForProcess proch
            return ret
    queryproc = 
             (proc "mero_call" args)
             {
               std_out = CreatePipe
             }

readMaybe :: Read a => String -> Maybe a
readMaybe = fmap fst . listToMaybe . reads
