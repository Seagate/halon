--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE LambdaCase #-}
module Helper
  ( withSudo
  , withEndpoint
  , withMeroRoot
  , getLnetNid
  , confdEndpoint
  , confd2Endpoint
  , halonEndpoint
  , getConfdEndpoint
  , getConfd2Endpoint
  , getHalonEndpoint
  , printErr
  ) where


import Control.Exception (bracket, onException)
import Control.Monad (when)
import Data.Maybe (catMaybes)
import Network.RPC.RPCLite
import System.Environment
    ( lookupEnv
    , getExecutablePath)
import System.Exit (exitSuccess)
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcess, callProcess)
import System.IO
import GHC.Environment (getFullArgs)

withSudo :: [String] -> IO () -> IO ()
withSudo envvars tests = do
  uid <- getEffectiveUserID
  when (uid /= 0) $ do
    prog <- getExecutablePath
    args <- getFullArgs
    env  <- catMaybes <$> mapM (\e -> fmap (\v -> e ++ "=" ++ v) <$> lookupEnv e)
                               envvars
    (callProcess "sudo" $ env ++ prog : args)
      `onException` (putStrLn "Error when running tests.")
    exitSuccess
  tests

withMeroRoot :: (String -> IO a) -> IO a
withMeroRoot f = lookupEnv "MERO_ROOT" >>= \case
  Nothing -> error "Please specify MERO_ROOT environment variable in order to run test."
  Just x  -> f x

getLnetNid :: IO String
getLnetNid = head . lines <$> readProcess "lctl" ["list_nids"] ""

-- | Endpoints environment names.
confdEndpoint, confd2Endpoint, halonEndpoint :: String
confdEndpoint = "SERVER1_ENDPOINT"
confd2Endpoint = "SERVER2_ENDPOINT"
halonEndpoint = "HALON_ENDPOINT" 

-- | Get confd endpoint address.
getConfdEndpoint :: IO String
getConfdEndpoint = lookupEnv confdEndpoint >>= \case
  Nothing -> (++) <$> getLnetNid <*> pure ":12345:34:101"
  Just nid -> return nid

-- | Get confd endpoint address.
getConfd2Endpoint :: IO String
getConfd2Endpoint = lookupEnv confdEndpoint >>= \case
  Nothing -> (++) <$> getLnetNid <*> pure ":12345:44:102"
  Just nid -> return nid

-- | Get halon endpoint address.
getHalonEndpoint :: IO String
getHalonEndpoint = lookupEnv halonEndpoint >>= \case
  Nothing -> (++) <$> getLnetNid <*> pure ":12345:35:401"
  Just nid -> return nid

withEndpoint :: RPCAddress -> (ServerEndpoint -> IO a) -> IO a
withEndpoint addr = bracket
    (listen addr listenCallbacks)
    stopListening
  where
    listenCallbacks = ListenCallbacks
      { receive_callback = \it _ -> do
          hPutStr stderr "Received: "
          print =<< unsafeGetFragments it
          return True
      }

printErr :: Show a => a -> IO ()
printErr = hPutStrLn stderr . show
