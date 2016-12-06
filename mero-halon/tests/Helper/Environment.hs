{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
-- |
-- Module    : Helper.Environment
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
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

withMeroRoot :: (String -> IO a) -> IO a
withMeroRoot f = lookupEnv "MERO_ROOT" >>= \case
  Nothing -> error "Please specify MERO_ROOT environment variable in order to run test."
  Just x  -> f x

-- | Return the value of the @TEST_LISTEN@ environment variable split
-- into host and port. Perform a minor check for formatting. 'Nothing'
-- if we variable unset or we couldn't parse @address:port@ pair.
getTestListenSplit :: IO (Maybe (String, Int))
getTestListenSplit = fmap (splitOn ":") <$> lookupEnv "TEST_LISTEN" >>= \case
  Just [ip, p] -> case (traverse readMaybe (splitOn "." ip), readMaybe p) of
    (Just ([_, _, _, _] :: [Word8]), Just p') -> return $ Just (ip, p')
    _ -> return Nothing
  _ -> return Nothing

-- | Retrieve an IP for the current host from @TEST_LISTEN@
-- ('getTestListenSplit') env variable.
testListenName :: IO String
testListenName = do
  mhost <- fmap fst <$> getTestListenSplit
  case mhost of
    Nothing -> fail "Couldn't retrieve host IP from TEST_LISTEN env var."
    Just h  -> return h
