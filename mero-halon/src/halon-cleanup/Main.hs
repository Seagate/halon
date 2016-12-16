{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : Main
-- Copyright : 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- @halon-cleanup.service@ driver. It is not intended to be ran
-- manually but through the service.
module Main (main) where

import Control.Monad (void, when)
import Data.Foldable (for_)
import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import HA.Replicator.Log (storageDir)
import Prelude hiding (log)
import System.Directory
import System.Exit
import System.IO
import System.Process
import System.SystemD.API (stopService, statusService)
import Text.Printf (printf)
import Text.Read (readMaybe)

-- | @'hPutStrLn' 'stdout'@
log :: String -> IO ()
log = hPutStrLn stdout

main :: IO ()
main = do
  -- Find PIDs of halond process(es) but don't do anything with them
  -- yet.
  log "Searching for halond processes."
  pids <- pidof "halond" >>= \case
    Left err -> do
      hPutStrLn stderr err
      return []
    Right pids -> do
      return pids
  -- Kill any halonctl instances that may be running.
  log "Killing any halonctl processes."
  pidof "halonctl" >>= \case
    Right pids'@(_ : _) ->
      void $ readProcessWithExitCodeVerbose "kill" ("-9" : map show pids')
    _ -> return ()
  -- Ask systemd to stop halond service if any is running. Assumption
  -- is that halond was started through systemd service.
  log "Stopping halond, if any."
  when (not $ null pids) $ do
    statusService "halond.service" >>= \case
      ExitSuccess -> stopService "halond.service" >>= \case
        ExitSuccess -> return ()
        ExitFailure rc -> do
          hPutStrLn stderr $ "halond.service stop failed with " <> show rc
          log "Trying to kill halond manually."
          void $ readProcessWithExitCodeVerbose "kill" ("-9" : map show pids)
      ExitFailure{} -> do
        log "halond service not running, killing halond manually."
        void $ readProcessWithExitCodeVerbose "kill" ("-9" : map show pids)
    -- Remove any m0trace files under /var/log that belong to halond
    -- PIDs we identified earlier.
    log "Removing halond m0trace files."
    for_ pids $ \p -> do
      removeFileIfExists $ printf "m0trace.%d" p
      removeFileIfExists $ printf "/var/log/m0trace.%d" p
  -- Remove persistent storage, if any. Maybe we should randomly try
  -- other directories such as /var/log and /var/lib/halon too. We
  -- could do better if /etc/sysconfig/halond set HALON_PERSISTENCE
  -- and if halond.service was always used.
  log $ "Trying to remove persistent storage data from common locations."
  removeDirectoryRecursiveIfExists storageDir
  removeDirectoryRecursiveIfExists "/var/log/halon-persistence"
  removeDirectoryRecursiveIfExists "/var/lib/halon/halon-persistence"
  -- Check for decision-log output in default locations specified by
  -- halon_roles.yaml. If they aren't there, just do nothing; not much
  -- we can do to get this information from elsewhere.
  removeFileIfExists "/var/log/halon.decision.log"
  removeFileIfExists "/var/log/halon.trace.log"
  -- bootstrap-cluster script usually puts things in /tmp/halond.log
  -- so try removing that too; once the script stops being used, we
  -- should remove this.
  removeFileIfExists "/tmp/halond.log"
  exitSuccess

-- | Remove the given file if it exists. Allow any exceptions to
-- propagate freely.
removeFileIfExists :: FilePath -> IO ()
removeFileIfExists fp = doesFileExist fp >>= \case
  True -> do
    log $ "Removing " <> fp
    removeFile fp
  False -> log $ printf "%s not found, not removing." fp

-- | Recursively remove specified directory if it exists.
removeDirectoryRecursiveIfExists :: FilePath -> IO ()
removeDirectoryRecursiveIfExists fp = doesDirectoryExist fp >>= \case
  True -> do
    log $ "Removing " <> fp
    removeDirectoryRecursive fp
  False -> log $ printf "%s not found, not removing." fp

-- | 'readProcessWithExitCode' but announces the command on 'stdout'
-- first. Does not provide any input to the process.
readProcessWithExitCodeVerbose :: FilePath -> [String] -> IO (ExitCode, String, String)
readProcessWithExitCodeVerbose cmd args = do
  hPutStrLn stdout . unwords $ "Running:" : cmd : args
  readProcessWithExitCode cmd args ""

-- | Run @pidof@ command for the given process and try to parse the results.
pidof :: String -> IO (Either String [Int])
pidof p = do
  (ec, sout, _) <- readProcessWithExitCodeVerbose "pidof" [p]
  return $ case ec of
    ExitSuccess -> case map words $ lines sout of
      pids : _ -> case mapMaybe readMaybe pids of
        [] -> Left $ "Could not parse ‘" <> sout <> "’ into pids."
        pids' -> Right pids'
      [] -> Right []
    ExitFailure rc -> Left $ "pidof failed with " <> show rc
