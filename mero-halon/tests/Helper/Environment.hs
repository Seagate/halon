{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
-- |
-- Module    : Helper.Environment
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Test helpers interacting with system environment.
module Helper.Environment
  ( getTestListenSplit
  , testListenName
  , withMeroRoot
  ) where

import Data.List.Split (splitOn)
import GHC.Word (Word8)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import Data.Foldable (for_)

withMeroRoot :: (String -> IO a) -> IO a
withMeroRoot f = lookupEnv "M0_SRC_DIR" >>= \case
  Nothing -> error "Please specify M0_SRC_DIR environment variable in order to run test."
  Just x  -> f x

-- | Return the value of the @TEST_LISTEN@ environment variable split
-- into host and port. Perform a minor check for formatting. 'Nothing'
-- if we variable unset or we couldn't parse @address:port@ pair.
getTestListenSplit :: IO (String, Int)
getTestListenSplit =
  lookupEnv "TEST_LISTEN" >>= \val -> case (splitOn ":") <$> val of
    Just [ip, p] -> case (traverse readMaybe (splitOn "." ip), readMaybe p) of
      (Just ([_, _, _, _] :: [Word8]), Just p') -> return (ip, p')
      _ -> warn val
    _ -> warn val
  where
    warn val = do
      for_ val $ putStrLn . ("Malformed TEST_LISTEN environment variable: " ++)
      return ("127.0.0.1", 0)

-- | Retrieve an IP for the current host from @TEST_LISTEN@
-- ('getTestListenSplit') env variable.
testListenName :: IO String
testListenName = fst <$> getTestListenSplit
