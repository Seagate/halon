{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- A helper module for repair process
module HA.RecoveryCoordinator.Castor.Drive.Rules.Repair.Internal where

import           Data.List (nub)
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC (ServiceType(CST_IOS))
import qualified Mero.Spiel as Spiel
import           Network.CEP

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
      , s <- G.connectedToU p M0.IsParentOf rg
      , CST_IOS <- [M0.s_type s]
      , any (`elem` M0.s_endpoints s) eps ]

-- | Check if IOS ready to run new task.
--
--  * [IDLE] - SNS is not doing any job
--  * [FAILED] - SNS failed previous job but cleared up and ready
iosReady :: Spiel.SnsCmStatus -> Bool
iosReady Spiel.M0_SNS_CM_STATUS_IDLE   = True
iosReady Spiel.M0_SNS_CM_STATUS_FAILED = True
iosReady _                             = False


-- | Check if IOS paused SNS operation.
--
--  * [IDLE] - SNS is not doing any job
--  * [FAILED] - SNS failed previous job but cleared up and ready
iosPaused :: Spiel.SnsCmStatus -> Bool
iosPaused Spiel.M0_SNS_CM_STATUS_PAUSED = True
iosPaused _                             = False

-- | Check if all IOS are alive according to halon.
allIOSOnline :: M0.Pool -> PhaseM LoopState l Bool
allIOSOnline pool = do
  svs <- getIOServices pool
  rg <- getLocalGraph
  let sts = [ M0.getState p rg
            | s <- svs
            , Just (p :: M0.Process) <- [G.connectedFrom1 M0.IsParentOf s rg]
            ]
  return $ all (== M0.PSOnline) sts

-- | Given a 'Pool', retrieve all associated IO services ('CST_IOS').
--
-- We use this helper both in repair module and spiel module so it lives here.
getIOServices :: M0.Pool -> PhaseM LoopState l [M0.Service]
getIOServices pool = getLocalGraph >>= \g -> return $ nub
  [ svc | pv <- G.connectedToU pool M0.IsRealOf g :: [M0.PVer]
        , rv <- G.connectedToU pv M0.IsParentOf g :: [M0.RackV]
        , ev <- G.connectedToU rv M0.IsParentOf g :: [M0.EnclosureV]
        , cv <- G.connectedToU ev M0.IsParentOf g :: [M0.ControllerV]
        , Just ct <- [G.connectedFrom1 M0.IsRealOf cv g :: Maybe M0.Controller]
        , Just nd <- [G.connectedFrom1 M0.IsOnHardware ct g :: Maybe M0.Node]
        , pr <- G.connectedToU nd M0.IsParentOf g :: [M0.Process]
        , svc@(M0.Service { M0.s_type = CST_IOS }) <-
            G.connectedToU pr M0.IsParentOf g
        ]
