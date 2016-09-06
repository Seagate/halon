{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- A helper module for repair process
module HA.RecoveryCoordinator.Castor.Drive.Rules.Repair.Internal where

import           Control.Exception (SomeException)
import           Data.List (nub)
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC (ServiceType(CST_IOS))
import qualified Mero.Spiel as Spiel
import           Network.CEP

-- | Just like 'repairedNotificationMessage', dispatch the appropriate
-- status checking routine depending on whether we're rebalancing or
-- repairing.
repairStatus :: M0.PoolRepairType -> M0.Pool
             -> PhaseM LoopState l (Either SomeException [Spiel.SnsStatus])
repairStatus M0.Rebalance = statusOfRebalanceOperation
repairStatus M0.Failure = statusOfRepairOperation

-- | Dispatch appropriate continue call depending on repair type
-- happening.
continueRepair :: M0.PoolRepairType -> M0.Pool
               -> PhaseM LoopState l (Maybe SomeException)
continueRepair M0.Rebalance pool = pure Nothing <* promulgateRC (PoolRebalanceRequest pool)
continueRepair M0.Failure pool = continueRepairOperation pool

-- | Quiesces the current repair.
-- TODO This is a bad name, since it aborts rebalance.
quiesceRepair :: M0.PoolRepairType -> M0.Pool
              -> PhaseM LoopState l (Maybe SomeException)
quiesceRepair M0.Rebalance = abortRebalanceOperation
quiesceRepair M0.Failure = quiesceRepairOperation

-- | Covert 'M0.PoolRepairType' into a 'ConfObjectState' that mero
-- expects: it's different depending on whether we are rebalancing or
-- repairing.
repairedNotificationMsg :: M0.PoolRepairType -> M0.ConfObjectState
repairedNotificationMsg M0.Rebalance = M0.M0_NC_ONLINE
repairedNotificationMsg M0.Failure = M0.M0_NC_REPAIRED

-- | Covert 'M0.PoolRepairType' into a 'ConfObjectState' that mero
-- expects: it's different depending on whether we are rebalancing or
-- repairing.
repairingNotificationMsg :: M0.PoolRepairType -> M0.ConfObjectState
repairingNotificationMsg M0.Rebalance = M0.M0_NC_REBALANCE
repairingNotificationMsg M0.Failure = M0.M0_NC_REPAIR

-- | Find only those services that are in a state of finished (or not
-- started) repair.
filterCompletedRepairs :: [Spiel.SnsStatus] -> [Spiel.SnsStatus]
filterCompletedRepairs = filter p
  where
    p (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_IDLE _) = True
    p (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_FAILED _) = True
    p _ = False

filterPausedRepairs :: [Spiel.SnsStatus] -> [Spiel.SnsStatus]
filterPausedRepairs = filter p
  where
    p (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_PAUSED _) = True
    p _ = False

-- | Find the processes associated with IOS services that have the
-- given endpoint(s).
failedNotificationIOS :: [String] -- ^ List of endpoints to check against
                      -> G.Graph -> [M0.Process]
failedNotificationIOS eps rg =
  [ p | p <- getAllProcesses rg
      , s <- G.connectedTo p M0.IsParentOf rg
      , CST_IOS <- [M0.s_type s]
      , any (`elem` M0.s_endpoints s) eps ]

-- | Check if we're able to use the IOS we know about for
-- repair/rebalance. Checks that all IOS are
-- 'Spiel.M0_SNS_CM_STATUS_IDLE' and the parent process is
-- 'M0.PSOnline'.
readyToUseIOS :: M0.Pool -> PhaseM LoopState l Bool
readyToUseIOS pool = allIOSOnline >>= \case
  False -> do
    phaseLog "warn" $ "Some IOS not online, not starting repair"
    return False
  True -> statusOfRepairOperation pool >>= \case
    Left err -> do
      phaseLog "warn" $ "Can't use IOS, IOS status returned " ++ show err
      return False
    Right sts
      | all iosReady sts -> return True
      | otherwise -> do
          phaseLog "warn" $ "Can't use IOS, not all IOS are ready " ++ show sts
          return False
  where
    allIOSOnline = do
      svs <- getIOServices pool
      rg <- getLocalGraph
      let sts = [ M0.getState p rg
                | s <- svs
                , p :: M0.Process <- G.connectedFrom M0.IsParentOf s rg
                ]
      return $ all (== M0.PSOnline) sts

    iosReady (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_IDLE _) = True
    iosReady _                                                 = False


-- | Given a 'Pool', retrieve all associated IO services ('CST_IOS').
--
-- We use this helper both in repair module and spiel module so it lives here.
getIOServices :: M0.Pool -> PhaseM LoopState l [M0.Service]
getIOServices pool = getLocalGraph >>= \g -> return $ nub
  [ svc | pv <- G.connectedTo pool M0.IsRealOf g :: [M0.PVer]
        , rv <- G.connectedTo pv M0.IsParentOf g :: [M0.RackV]
        , ev <- G.connectedTo rv M0.IsParentOf g :: [M0.EnclosureV]
        , cv <- G.connectedTo ev M0.IsParentOf g :: [M0.ControllerV]
        , ct <- G.connectedFrom M0.IsRealOf cv g :: [M0.Controller]
        , nd <- G.connectedFrom M0.IsOnHardware ct g :: [M0.Node]
        , pr <- G.connectedTo nd M0.IsParentOf g :: [M0.Process]
        , svc@(M0.Service { M0.s_type = CST_IOS }) <- G.connectedTo pr M0.IsParentOf g
        ]
