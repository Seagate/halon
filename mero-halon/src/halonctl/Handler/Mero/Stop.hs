{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData      #-}
-- |
-- Module    : Handler.Mero.Stop
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Stop
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Control.Monad
import           Data.Foldable
import           Data.Function (fix)
import           Data.Monoid ((<>))
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.Resources.Mero.Note (showFid)
import           Handler.Mero.Helpers
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure, exitSuccess)
import           Text.Printf (printf)

data Options = Options
  { _so_silent :: Bool
  , _so_async :: Bool
  , _so_timeout :: Int
  , _so_reason :: String }
  deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
    ( Opt.long "silent"
    <> Opt.help "Do not print any output" )
  <*> Opt.switch
    ( Opt.long "async"
    <> Opt.help "Don't wait for stop to happen." )
  <*> Opt.option Opt.auto
    ( Opt.metavar "TIMEOUT(µs)"
    <> Opt.long "timeout"
    <> Opt.help "How long to wait for successful cluster stop before halonctl gives up on waiting."
    <> Opt.value 600000000
    <> Opt.showDefault )
  <*> Opt.strOption
    ( Opt.long "reason"
    <> Opt.help "Reason for stopping the cluster"
    <> Opt.metavar "REASON"
    <> Opt.value "unspecified" )

run :: [NodeId] -> Options -> Process ()
run nids (Options silent async stopTimeout reason) = do
  say' "Stopping cluster."
  self <- getSelfPid
  clusterCommand nids Nothing (ClusterStopRequest reason) return >>= \case
    StateChangeFinished -> do
      say' "Cluster already stopped"
      -- Bail out early, do not start monitor which won't receive any
      -- messages.
      liftIO exitSuccess
    StateChangeStarted -> do
      say' "Cluster stop initiated."

  promulgateEQ nids (MonitorClusterStop self) >>= flip withMonitor wait
  case async of
    True -> return ()
    False -> do
      void . spawnLocal $ receiveTimeout stopTimeout [] >> usend self ()
      fix $ \loop -> void $ receiveWait
        [ match $ \() -> do
            say' $ "Giving up on waiting for cluster stop after " ++ show stopTimeout ++ "µs"
            liftIO exitFailure
        , match $ \csd -> do
            outputClusterStopDiff csd
            case _csp_cluster_stopped csd of
              Nothing -> loop
              Just ClusterStopOk -> liftIO exitSuccess
              Just ClusterStopFailed{} -> liftIO exitFailure
        ]
  where
    say' msg = if silent then return () else liftIO (putStrLn msg)
    wait = void (expect :: Process ProcessMonitorNotification)
    outputClusterStopDiff :: ClusterStopDiff -> Process ()
    outputClusterStopDiff ClusterStopDiff{..} = do
      let o `movedTo` n = show o ++ " -> " ++ show n
          formatChange obj os ns = showFid obj ++ ": " ++ os `movedTo` ns
          warn m = say' $ "Warning: " ++ m
      for_ _csp_procs $ \(p, o, n) -> say' $ formatChange p o n
      for_ _csp_servs $ \(s, o, n) -> say' $ formatChange s o n
      for_ _csp_disposition $ \(od, nd) -> do
        say' $ "Cluster disposition: " ++ od `movedTo` nd

      let (op, np) = _csp_progress
      when (op /= np) $ do
        say' $ printf "Progress: %.2f%% -> %.2f%%" (fromRational op :: Float) (fromRational np :: Float)

      for_ _csp_cluster_stopped $ \case
        ClusterStopOk -> say' "Cluster stopped successfully"
        ClusterStopFailed failMsg -> say' $ "Cluster stop failed: " ++ failMsg

      if op > np then warn "Cluster stop progress decreased!" else return ()
      for_ _csp_warnings $ \w -> warn w
