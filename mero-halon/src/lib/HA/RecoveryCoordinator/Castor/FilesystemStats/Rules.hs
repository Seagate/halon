-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Module rules for FilesystemStats entity.

{-# LANGUAGE PackageImports #-}

module HA.RecoveryCoordinator.Castor.FilesystemStats.Rules
  ( rules
    -- * Individual rules exported for tests.
  , periodicQueryStats
  ) where

import           HA.RecoveryCoordinator.Actions.Mero (getClusterStatus)
import           HA.RecoveryCoordinator.Castor.FilesystemStats.Events
  (StatsUpdated(..))
import           HA.RecoveryCoordinator.Mero.Actions.Conf (getRoot, theProfile)
import           HA.RecoveryCoordinator.Mero.Actions.Core (mkUnliftProcess)
import           HA.RecoveryCoordinator.Mero.Actions.Spiel
  ( withSpielIO
  , withRConfIO
  )
import           HA.RecoveryCoordinator.RC.Actions
  ( RC
  , getGraph
  , modifyGraph
  , notify
  )
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import qualified HA.Resources.Mero as M0
import qualified Mero.Spiel as Spiel
import           Network.CEP

import           Control.Arrow (left, right)
import           Control.Distributed.Process (getSelfPid, liftIO, usend)
import           Control.Exception (try)
import           Control.Monad (void)
import           Data.Binary (Binary)

import qualified "distributed-process-scheduler" System.Clock as C

-- | Internal response with FS stats.
newtype FSStatsFetched = FSStatsFetched (Either String M0.FilesystemStats)
  deriving Binary

-- | Interval between stats queries (s)
queryInterval :: Int
queryInterval = 5 * 60

-- | Periodically queries the filesystem stats and updates this in the
--   resource graph.
periodicQueryStats :: Definitions RC ()
periodicQueryStats = define "castor::filesystem::stats::fetch" $ do

  stats_fetch <- phaseHandle "stats_fetch"
  stats_fetched <- phaseHandle "stats_fetched"

  directly stats_fetch $ do
    Log.rcLog' Log.DEBUG "Querying filesystem stats."

    unlift <- mkUnliftProcess
    next <- liftProcess $ do
      rc <- getSelfPid
      return $ \x -> do
        now <- liftIO $ M0.TimeSpec <$> C.getTime C.Realtime
        usend rc . FSStatsFetched
                  . left (\e -> show (e :: IOError))
                  . right (M0.FilesystemStats now)
                  $ x

    mstatus <- getClusterStatus <$> getGraph
    case mstatus of
      Nothing -> Log.rcLog' Log.DEBUG "No M0.MeroClusterState found in graph."
      Just (M0.MeroClusterState _ rl _) | rl <= M0.BootLevel 1 ->
        Log.rcLog' Log.DEBUG $ "Cluster is on runlevel " ++ show rl
      Just _ -> do
        -- XXX-MULTIPOOLS: We should support multiple profiles here.
        mprof <- theProfile
        void . withSpielIO . withRConfIO mprof
          $ try Spiel.filesystemStatsFetch >>= unlift . next
        continue stats_fetched
    continue $ timeout queryInterval stats_fetch

  setPhase stats_fetched $ \(FSStatsFetched q) -> do
    case q of
      Left se ->
        Log.rcLog' Log.WARN $ "Could not fetch filesystem stats: " ++ se
      Right stats -> do
        Just root <- getRoot
        modifyGraph $ G.connect root Has stats
        notify $ StatsUpdated stats
    continue $ timeout queryInterval stats_fetch

  start stats_fetch Nothing

-- | Set of rules querying filesystem information.
rules :: Definitions RC ()
rules = sequence_
  [ periodicQueryStats ]
