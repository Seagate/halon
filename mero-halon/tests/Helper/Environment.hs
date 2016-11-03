-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
{-# LANGUAGE LambdaCase #-}
module Helper.Environment
  ( withMeroRoot
  , confdEndpoint
  , confd2Endpoint
  , getLnetNid
  , getTestListen
  , getTestListenSplit
  , systemHostname
  , testListenName
  ) where

import Control.Arrow (second)
import Network.BSD
import System.Environment
    ( lookupEnv )
import System.IO.Unsafe
import System.Process (readProcess)

withMeroRoot :: (String -> IO a) -> IO a
withMeroRoot f = lookupEnv "MERO_ROOT" >>= \case
  Nothing -> error "Please specify MERO_ROOT environment variable in order to run test."
  Just x  -> f x

getLnetNid :: IO String
getLnetNid = head . lines <$> readProcess "lctl" ["list_nids"] ""

-- | Endpoints environment names.
confdEndpoint, confd2Endpoint :: String
confdEndpoint = "SERVER1_ENDPOINT"
confd2Endpoint = "SERVER2_ENDPOINT"

-- | Return the value of the @TEST_LISTEN@ environment variable.
-- Error out if the variable is not set.
getTestListen :: IO String
getTestListen = lookupEnv "TEST_LISTEN" >>= \case
  Nothing ->
    error "environment variable TEST_LISTEN is not set; example: 192.0.2.1:0"
  Just str -> return str

-- | Return the value of the @TEST_LISTEN@ environment variable split
-- into host and port. Error out if the variable is not set. Also see
-- 'getTestListen'.
getTestListenSplit :: IO (String, String)
getTestListenSplit = second (drop 1) . break (== ':') <$> getTestListen

systemHostname :: String
systemHostname = unsafePerformIO getHostName

testListenName :: String
testListenName = unsafePerformIO $ do
  mhost <- fmap (fst . (span (/=':'))) <$> lookupEnv "TEST_LISTEN"
  case mhost of
    Nothing -> getLnetNid
    Just h  -> return h
