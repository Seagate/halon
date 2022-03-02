{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- A helper module for repair process
module HA.RecoveryCoordinator.Castor.Drive.Rules.Repair.Internal where

import           Data.List (nub)
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC (ServiceType(CST_IOS))
import           Mero.Lnet
import qualified Mero.Spiel as Spiel
import           Network.CEP

-- | Get a 'Tr.Transition' coresponding to a pool completing
-- repair/rebalance.
snsCompletedTransition :: M0.PoolRepairType -> Tr.Transition M0.Pool
snsCompletedTransition M0.Repair = Tr.poolRepairComplete
snsCompletedTransition M0.Rebalance = Tr.poolRebalanceComplete

-- | Covert 'M0.PoolRepairType' into a 'ConfObjectState' that mero
-- expects: it's different depending on whether we are rebalancing or
-- repairing.
repairedNotificationMsg :: M0.PoolRepairType -> M0.ConfObjectState
repairedNotificationMsg M0.Repair = M0.M0_NC_REBALANCE
repairedNotificationMsg M0.Rebalance = M0.M0_NC_ONLINE

-- | Covert 'M0.PoolRepairType' into a 'ConfObjectState' that mero
-- expects: it's different depending on whether we are rebalancing or
-- repairing.
repairingNotificationMsg :: M0.PoolRepairType -> M0.ConfObjectState
repairingNotificationMsg M0.Repair = M0.M0_NC_REPAIR
repairingNotificationMsg M0.Rebalance = M0.M0_NC_REBALANCE

-- | Find only those services that are in a state of finished (or not
-- started) repair.
filterCompletedRepairs :: [Spiel.SnsStatus] -> [Spiel.SnsStatus]
filterCompletedRepairs = filter (iosReady . Spiel._sss_state)

-- | Find any 'iosPaused' statuses.
filterPausedRepairs :: [Spiel.SnsStatus] -> [Spiel.SnsStatus]
filterPausedRepairs = filter (iosPaused . Spiel._sss_state)

-- | Check if any 'Spiel.SnsStatus' came back as 'Spiel.M0_SNS_CM_STATUS_FAILED'.
anyIOSFailed :: [Spiel.SnsStatus] -> Bool
anyIOSFailed = any (p . Spiel._sss_state)
  where
    p Spiel.M0_SNS_CM_STATUS_FAILED = True
    p _                             = False

-- | Find the processes associated with IOS services that have the
-- given endpoint(s).
failedNotificationIOS :: [Endpoint] -- ^ List of endpoints to check against
                      -> G.Graph -> [M0.Process]
failedNotificationIOS eps rg =
  [ p | p <- Process.getAll rg
      , s <- G.connectedTo p M0.IsParentOf rg
      , CST_IOS <- [M0.s_type s]
      , any (`elem` M0.s_endpoints s) eps ]

-- | Check if IOS ready to run new task.
--
--  * [IDLE] - SNS is not doing any job
--  * [FAILED] - SNS failed previous job but cleared up and ready
--  * [PAUSED] - SNS job has been paused by quiesce, but we can do new things.
iosReady :: Spiel.SnsCmStatus -> Bool
iosReady Spiel.M0_SNS_CM_STATUS_IDLE   = True
iosReady Spiel.M0_SNS_CM_STATUS_FAILED = True
iosReady Spiel.M0_SNS_CM_STATUS_PAUSED = True
iosReady _                             = False


-- | Check if IOS 'Spiel.M0_SNS_CM_STATUS_PAUSED' SNS operation.
iosPaused :: Spiel.SnsCmStatus -> Bool
iosPaused Spiel.M0_SNS_CM_STATUS_PAUSED = True
iosPaused _                             = False

-- | Check if all IOS are alive according to halon.
allIOSOnline :: M0.Pool -> PhaseM RC l Bool
allIOSOnline pool = do
  svs <- getIOServices pool
  rg <- getGraph
  let sts = [ M0.getState p rg
            | s <- svs
            , Just (p :: M0.Process) <- [G.connectedFrom M0.IsParentOf s rg]
            ]
  return $ all (== M0.PSOnline) sts

-- | Given a 'Pool', retrieve all associated IO services ('CST_IOS').
--
-- We use this helper both in repair module and spiel module so it lives here.
getIOServices :: M0.Pool -> PhaseM RC l [M0.Service]
getIOServices pool = getGraph >>= \g -> return $ nub
  [ svc | pv <- G.connectedTo pool M0.IsParentOf g :: [M0.PVer]
        , sv <- G.connectedTo pv M0.IsParentOf g :: [M0.SiteV]
        , rv <- G.connectedTo sv M0.IsParentOf g :: [M0.RackV]
        , ev <- G.connectedTo rv M0.IsParentOf g :: [M0.EnclosureV]
        , cv <- G.connectedTo ev M0.IsParentOf g :: [M0.ControllerV]
        , Just ct <- [G.connectedFrom M0.IsRealOf cv g :: Maybe M0.Controller]
        , Just nd <- [G.connectedFrom M0.IsOnHardware ct g :: Maybe M0.Node]
        , pr <- G.connectedTo nd M0.IsParentOf g :: [M0.Process]
        , svc@(M0.Service { M0.s_type = CST_IOS }) <-
            G.connectedTo pr M0.IsParentOf g
        ]
