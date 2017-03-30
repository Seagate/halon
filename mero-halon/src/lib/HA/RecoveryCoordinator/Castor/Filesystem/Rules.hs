-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module rules for Filesystem entity.

{-# LANGUAGE PackageImports             #-}

module HA.RecoveryCoordinator.Castor.Filesystem.Rules
  ( rules
    -- * Individual rules exported for tests.
  , periodicQueryStats
  ) where

import HA.RecoveryCoordinator.Actions.Mero (getClusterStatus)
import HA.RecoveryCoordinator.Castor.Filesystem.Events ( StatsUpdated(..) )
import HA.RecoveryCoordinator.Mero.Actions.Conf (getFilesystem)
import HA.RecoveryCoordinator.Mero.Actions.Core (mkUnliftProcess)
import HA.RecoveryCoordinator.Mero.Actions.Spiel
  ( withSpielIO
  , withRConfIO
  )
import HA.RecoveryCoordinator.RC.Actions
  ( RC
  , getLocalGraph
  , modifyGraph
  , notify
  )
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0

import qualified Mero.Spiel as Spiel

import Control.Arrow (left, right)
import Control.Distributed.Process
  ( getSelfPid
  , liftIO
  , usend
  )
import Control.Exception ( try )
import Control.Monad (void)

import Data.Binary (Binary)

import Network.CEP

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

    mfs <- getFilesystem
    status <- getClusterStatus <$> getLocalGraph
    case ((,) <$> mfs <*> status) of
      Just (fs, M0.MeroClusterState _ rl _) | rl > M0.BootLevel 1 -> do
        mp <- G.connectedTo R.Cluster R.Has <$> getLocalGraph
        void . withSpielIO . withRConfIO mp
          $ try (Spiel.filesystemStatsFetch (M0.fid fs)) >>= unlift . next
        put Local $ Just fs
        continue stats_fetched
      Nothing ->
        Log.rcLog' Log.DEBUG "No filesystem found in graph."
      Just (_, M0.MeroClusterState _ rl _) ->
        Log.rcLog' Log.DEBUG $ "Cluster is on runlevel " ++ show rl
    continue $ timeout queryInterval stats_fetch

  setPhase stats_fetched $ \(FSStatsFetched q) -> do
    case q of
      Left se -> Log.rcLog' Log.WARN $ "Could not fetch filesystem stats: "
                                    ++ se
      Right stats -> do
        Just fs <- get Local
        modifyGraph $ G.connect fs R.Has stats
        notify $ StatsUpdated fs stats
    continue $ timeout queryInterval stats_fetch

  start stats_fetch Nothing

-- | Set of rules querying filesystem information.
rules :: Definitions RC ()
rules = sequence_
  [ periodicQueryStats ]
