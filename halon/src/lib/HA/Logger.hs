{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module:     Control.Distributed.Process.Logs
-- Copyright:  (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
--
-- Wrapper to generate trace log subsystem. Trace logs - are
-- special kind of logs that logs internal state. By default
-- loggers are disabled as may have negative perfomance impact 
-- and may make logs unusable, because they will generate too
-- much logs, that are not useful unless debuging.
--
-- Such logs can be enabled either statically via setting
-- environment labels or in runtime with 'silenceLogger', 
-- 'verboseLogger' calls.
module HA.Logger
  ( -- * Public API
    mkHalonTracer
  , mkHalonTracerIO
  , silenceLogger
  , verboseLogger
    -- * D-p internals
  , __remoteTable
  , silenceLogger__static
  , silenceLogger__sdict
  , silenceLogger__tdict
  , verboseLogger__static
  , verboseLogger__sdict
  , verboseLogger__tdict
  ) where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Monad (when)
import Data.Foldable (for_)
import Data.Char
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe
import System.Environment

-- | List of all loggers.
loggers :: MVar (Map String (IORef Bool))
loggers = unsafePerformIO $ newMVar Map.empty

-- | Internal function to update (or create) certain logger.
updateLogger :: String -- ^ Subsystem name
             -> Bool -- ^ Enable logging subsystem?
             -> IO (IORef Bool)
updateLogger s b = modifyMVar loggers $ \m -> do
  case Map.lookup s m of
    Nothing -> do
      ref <- newIORef b
      return (Map.insert s ref m, ref)
    Just ref -> do
      writeIORef ref b
      return (m, ref)

-- | Disable log output in certain subsystem.
-- 
-- This method can be called remotely.
silenceLogger :: String -> Process ()
silenceLogger subsystem = liftIO $ withMVar loggers $ \m ->
  for_ (Map.lookup subsystem m) $ \ref ->
    writeIORef ref False

-- | Enable log output in certain subsystem.
-- 
-- This method can be called remotely.
verboseLogger :: String -> Process ()
verboseLogger subsystem = liftIO $ withMVar loggers $ \m ->
  for_ (Map.lookup subsystem m) $ \ref ->
    writeIORef ref True

-- | Create a logger that could be enabled by setting
-- proper environment variable
--
-- Examples:
--
-- @
-- logger :: String -> Process ()
-- logger = mkHalonTracer "EQ.producer"
-- @
--
-- Now we could run program with:
--
-- @
-- HALON_TRACING="EQ.producer smth-else" ./program-name
-- @
--
-- and get logging enabled, it's possible to use @*@ in
-- @HALON_TRACING@ variable, then all subsystems will be enabled
mkHalonTracer :: String
              -> (String -> Process ())
mkHalonTracer subsystem = unsafePerformIO $ do
    mx  <- lookupEnv "HALON_TRACING"
    let status = case mx of
             Nothing -> False
             Just ss ->
               let subsystems = words $ map toLower ss
               in (map toLower subsystem) `elem` subsystems || "*" `elem` subsystems
    ref <- updateLogger subsystem status
    let check f = do
          b <- liftIO $ readIORef ref
          when b f
    if schedulerIsEnabled
    then return $ \tagged -> check $ do
           self <- getSelfPid
           liftIO $ hPutStrLn stderr $ show self ++ ": " ++ tagged
    else return $ check . say

-- | Create a logger in IO that could be enabled by setting
-- proper environment variable
--
-- Examples:
--
-- @
-- logger :: String -> IO ()
-- logger = mkHalonTracer "EQ.producer"
-- @
--
-- Now we could run program with:
--
-- @
-- HALON_TRACING="EQ.producer smth-else" ./program-name
-- @
--
-- and get logging enabled, it's possible to use @*@ in
-- @HALON_TRACING@ variable, then all subsystems will be enabled
mkHalonTracerIO :: String
                -> (String -> IO ())
mkHalonTracerIO subsystem = unsafePerformIO $ do
    mx  <- lookupEnv "HALON_TRACING"
    let status = case mx of
             Nothing -> False
             Just ss ->
               let subsystems = words $ map toLower ss
               in (map toLower subsystem) `elem` subsystems || "*" `elem` subsystems
    ref <- updateLogger subsystem status
    let check f = do
          b <- liftIO $ readIORef ref
          when b f
        prependSubsystem x = subsystem ++ ": " ++ x
    return $ check . hPutStrLn stderr . prependSubsystem

remotable ['silenceLogger, 'verboseLogger]
