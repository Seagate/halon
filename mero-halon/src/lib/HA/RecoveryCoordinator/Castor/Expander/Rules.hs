{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeOperators     #-}
{-# LANGUAGE ViewPatterns      #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Expander.Rules
-- Copyright : (C) 2016-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Module rules for expander card.
module HA.RecoveryCoordinator.Castor.Expander.Rules (rules) where

import           Control.Arrow ((***))
import           Control.Distributed.Process (liftIO)
import           Control.Lens
import           Control.Monad (forM_)
import           Control.Monad.Trans.Maybe
import           Data.List (nub)
import           Data.Maybe (isJust, listToMaybe, mapMaybe)
import           Data.Proxy
import qualified Data.Text as T
import           Data.UUID.V4 (nextRandom)
import           Data.Vinyl
import           HA.EventQueue
import           HA.RecoveryCoordinator.Castor.Drive.Events (ExpanderReset(..))
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events
import           HA.RecoveryCoordinator.Mero.Actions.Conf
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State
import           HA.RecoveryCoordinator.Mero.Transitions
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Services.SSPL.LL.CEP (sendNodeCmd)
import           HA.Services.SSPL.LL.RC.Actions (fldCommandAck, mkDispatchAwaitCommandAck)
import           HA.Services.SSPL.LL.Resources (NodeCmd(..), RaidCmd(..))
import           Network.CEP

-- | Expander reset rules.
rules :: Definitions RC ()
rules = sequence_
  [ ruleReassembleRaid ]

{- |
Halon needs to be able to understand and handle a RAID array failure due to a
SAS expander reset event.

The expected timeline of events from SSPL in the case of an expander reset is
as follows:

Expander reset event
84x Drive removed event
RAID failure event
84x Drive added event

During this time it is highly likely that multiple Mero error events will be
received as loss of all data drives, subsequent reappearance of the data drives
but continued loss of the meta data array will happen.

The recovery of this scenario is as follows:

Upon expander reset event:
Put that SSU in a transient error state
Tell SSPL to disable swap on the SSU
Stop all Mero services on that SSU
Tell SSPL to umount the /var/mero mount point
Tell SSPL to stop the RAID array
Tell SSPL to reassemble the RAID array
(/var/mero and swap will automatically mount and re-enable themselves)
Restart Mero services on the SSU
Mark SSU as healthy.
-}
ruleReassembleRaid :: Definitions RC ()
ruleReassembleRaid =
    define "castor::expander::reassembleRaid" $ do
      expander_reset_evt <- phaseHandle "expander_reset_evt"
      notify_failed <- phaseHandle "notify_failed"
      stop_mero_services <- phaseHandle "stop_mero_services"
      unmount <- phaseHandle "unmount"
      stop_raid <- phaseHandle "stop_raid"
      reassemble_raid <- phaseHandle "reassemble_raid"
      start_mero_services <- phaseHandle "start_mero_services"
      mero_services_started <- phaseHandle "mero_services_started"
      mark_mero_healthy <- phaseHandle "mark_mero_healthy"
      nodeup_timeout <- phaseHandle "nodeup_timeout"
      failed <- phaseHandle "failed"
      finish <- phaseHandle "finish"
      tidyup <- phaseHandle "tidyup"
      dispatcher <- mkDispatcher
      node_stop_result <- phaseHandle "node_stop_result"
      sspl_notify_done <- mkDispatchAwaitCommandAck dispatcher failed showLocality
      mero_notifier <- mkNotifierSimpleAct dispatcher $ do
        -- We have received mero notification so ramp up the timeout
        -- in case we're waiting for SSPL. This is necessary in case
        -- we're waiting for both mero notification and SSPL ack:
        -- without this, we would either only wait for a short time
        -- for each message (wrong) or wait a long time
        -- ('_hv_expander_sspl_ack_timeout') for mero notification too
        -- (if not wrong then waste of time).
        t <- getHalonVar _hv_expander_sspl_ack_timeout
        onTimeout t notify_failed

      setPhase expander_reset_evt $ \(HAEvent eid (ExpanderReset enc)) -> do
        todo eid

        mm0 <- runMaybeT $ do
          m0enc <- MaybeT $ getGraph <&> encToM0Enc enc
          m0node <- MaybeT $ getGraph <&> \rg -> listToMaybe
            [ node | ctrl <- G.connectedTo m0enc M0.IsParentOf rg :: [M0.Controller]
                   , Just node <- [G.connectedFrom M0.IsOnHardware ctrl rg]
                   ]
          return (m0enc, m0node)
        mnode <- getGraph <&> \rg -> listToMaybe
          [ (host, node)
          | host <- G.connectedTo enc R.Has rg :: [R.Host]
          , node <- G.connectedTo host R.Runs rg
          ]
        raidDevs <- getGraph <&> \rg -> let
            extractRaidDev (R.DIRaidDevice x) = Just x
            extractRaidDev _ = Nothing
          in nub $ mapMaybe extractRaidDev [
              lbl | slot <- G.connectedTo enc R.Has rg :: [R.Slot]
                  , Just d <- [G.connectedFrom R.Has slot rg] :: [Maybe R.StorageDevice]
                  , lbl <- G.connectedTo d R.Has rg :: [R.DeviceIdentifier]
                  ]

        -- If we don't have the node, we can't do much, but it is valid
        -- that we might not have to deal with Mero (this can happen on the
        -- CMU), so we have to deal with that.
        case (mnode, raidDevs) of
          (Just (host, node), (_:_)) -> do
            modify Local $ rlens fldHardware . rfield .~ Just (enc, host, node)
            modify Local $ rlens fldUUID . rfield .~ (Just eid)
            modify Local $ rlens fldRaidDevices . rfield .~ raidDevs

            -- Mark that the host is undergoing RAID reassembly
            modifyGraph $ G.connect host R.Is R.ReassemblingRaid

            -- Set default jump parameters. If no Mero, just stop RAID directly
            onSuccess stop_raid
            t <- getHalonVar _hv_expander_sspl_ack_timeout
            onTimeout t notify_failed

            -- Mark enclosure as transiently failed. This should cascade down to
            -- controllers, disks etc.
            forM_ mm0 $ \(m0enc, m0node) -> do
              notifications <- applyStateChanges [stateSet m0enc enclosureTransient]
              setExpectedNotifications notifications
              modify Local $ rlens fldM0 . rfield .~ Just (m0enc, m0node)
              -- Wait for Mero notification, and also jump to stop_mero_services
              waitFor mero_notifier
              onTimeout 10 notify_failed
              onSuccess stop_mero_services

            showLocality

            -- Tell SSPL to disable swap
            cmdUUID <- liftIO $ nextRandom
            sent <- sendNodeCmd [node] (Just cmdUUID) $ SwapEnable False

            if sent
            then do
              modify Local $ rlens fldCommandAck . rfield .~ [cmdUUID]
              waitFor sspl_notify_done
              continue dispatcher
            else do
              -- TODO Send some kind of 'CannotTalkToSSPL' message
              Log.rcLog' Log.ERROR $ "Expander reset event received for enclosure, "
                              ++ "but we are unable to contact SSPL on that "
                              ++ "node."
              continue failed
          (_, []) -> do
            Log.rcLog' Log.DEBUG $ "Expander reset event received for enclosure "
                           ++ "but there were no RAID devices to reassemble."
            done eid
          (Nothing, _) -> do
            -- TODO this is pretty interesting - should we raise an IEM?
            Log.rcLog' Log.WARN $ "Expander reset event received for enclosure, "
                              ++ "but there was no corresponding node."
            done eid

      directly stop_mero_services $ do
        showLocality
        Just (_, _, node) <- gets Local (^. rlens fldHardware . rfield)
        j <- startJob $ MaintenanceStopNode node
        modify Local $ rlens fldNodeJob . rfield .~ Just j
        Log.rcLog' Log.DEBUG $ "Stopping node " ++ show node
        continue node_stop_result

      setPhaseIf node_stop_result ourJob $ \case
        MaintenanceStopNodeOk{} -> continue unmount
        failure -> do
          Log.rcLog' Log.ERROR $ "Failure in expander reset: " ++ show failure
          continue failed

      directly unmount $ do
        showLocality
        Just (_, _, node) <- gets Local (^. rlens fldHardware . rfield)
        cmdUUID <- liftIO $ nextRandom
        -- TODO magic constant
        sent <- sendNodeCmd [node] (Just cmdUUID) $ Unmount $ T.pack "/var/mero"

        if sent
        then do
          modify Local $ rlens fldCommandAck . rfield .~ [cmdUUID]
          waitFor sspl_notify_done
          onSuccess stop_raid

          continue dispatcher
        else do
          Log.rcLog' Log.ERROR $ "Expander reset event received for enclosure "
                              ++ ", but we are unable to contact SSPL on that "
                              ++ "node."
          continue failed

      directly stop_raid $ do
        showLocality
        Just (_, _, node) <- gets Local (^. rlens fldHardware . rfield)
        raidDevs <- gets Local (^. rlens fldRaidDevices . rfield)

        forM_ raidDevs $ \dev -> do
          cmdUUID <- liftIO $ nextRandom
          sent <- sendNodeCmd [node] (Just cmdUUID)
                  $ NodeRaidCmd (T.pack dev) RaidStop

          if sent
          then
            modify Local $ rlens fldCommandAck . rfield %~ (cmdUUID :)
          else do
            Log.rcLog' Log.WARN $ "Tried to stop RAID device "
                              ++ (show dev)
                              ++ ", but we are unable to contact SSPL on that "
                              ++ "node."

        waitFor sspl_notify_done
        onSuccess reassemble_raid

        continue dispatcher

      directly reassemble_raid $ do
        showLocality
        Just (_, _, node) <- gets Local (^. rlens fldHardware . rfield)
        cmdUUID <- liftIO $ nextRandom
        sent <- sendNodeCmd [node] (Just cmdUUID) $ NodeRaidCmd (T.pack "--scan") (RaidAssemble [])

        if sent
        then do
          modify Local $ rlens fldCommandAck . rfield .~ [cmdUUID]
          waitFor sspl_notify_done

          m0 <- isJust <$> gets Local (^. rlens fldM0 . rfield)
          if m0
          then
            onSuccess start_mero_services
          else
            onSuccess finish

          continue dispatcher
        else do
          showLocality
          Log.rcLog' Log.WARN $ "Tried to reassemble RAID devices"
                             ++ ", but we are unable to contact SSPL on that "
                             ++ "node."
          continue failed

      directly start_mero_services $ do
        showLocality
        (Just (_, m0node)) <- gets Local (^. rlens fldM0 . rfield)
        j <- startJob $ StartProcessesOnNodeRequest m0node
        modify Local $ rlens fldNodeJob . rfield .~ Just j
        t <- getHalonVar _hv_expander_node_up_timeout
        switch [mero_services_started, timeout t failed]

      setPhaseIf mero_services_started ourJob $ \case
        NodeProcessesStarted{} -> continue mark_mero_healthy
        NodeProcessesStartTimeout{} -> continue nodeup_timeout
        NodeProcessesStartFailure{} -> do
          showLocality
          Log.rcLog' Log.ERROR $ "Cannot start kernel, although it was never "
                          ++ "stopped."
          continue failed

      -- Mark the enclosure as healthy again
      directly mark_mero_healthy $ do
        Just (m0enc, _) <- gets Local (^. rlens fldM0 . rfield)
        notifications <- applyStateChanges [stateSet m0enc enclosureOnline]
        setExpectedNotifications notifications
        waitFor mero_notifier
        onTimeout 10 notify_failed
        onSuccess finish

        continue dispatcher

      directly finish $ do
        showLocality
        Log.rcLog' Log.DEBUG $ "Raid reassembly complete."
        continue tidyup

      directly notify_failed $ do
        showLocality
        waiting <- gets Local (^. rlens fldDispatch . rfield . waitPhases)
        Log.rcLog' Log.ERROR $ "Timeout whilst waiting for phases: "
                        ++ show waiting
        continue failed

      directly nodeup_timeout $ do
        showLocality
        Log.rcLog' Log.ERROR $ "Timeout whilst waiting for Mero processes to "
                        ++ "restart."
        continue failed

      directly failed $ do
        showLocality
        Log.rcLog' Log.ERROR $ "Error during expander reset handling."
        -- TODO enclosure restart?
        continue tidyup

      -- Tidy up phase, runs after either a successful or unsuccessful
      -- completion and:
      -- - Removes the raid reassembly marker on the host
      -- - Acknowledges the message
      directly tidyup $ do
        Just uuid <- gets Local (^. rlens fldUUID . rfield)
        Just (_, host, _) <- gets Local (^. rlens fldHardware . rfield)
        modifyGraph $ G.disconnect host R.Is R.ReassemblingRaid
        waitClear
        done uuid

      startFork expander_reset_evt (args expander_reset_evt)

  where
    -- Enclosure, node
    fldHardware = Proxy :: Proxy '("hardware", Maybe (R.Enclosure, R.Host, R.Node))
    -- RAID devices
    fldRaidDevices = Proxy :: Proxy '("raidDevices", [String])
    -- Using Mero?
    fldM0 = Proxy :: Proxy '("meroStuff", Maybe (M0.Enclosure, M0.Node))
    -- We're waiting for processes on node to stop
    fldNodeJob = Proxy :: Proxy '("node-job", Maybe ListenerId)

    args st = fldHardware =: Nothing
       <+> fldNotifications =: []
       <+> fldUUID =: Nothing
       <+> fldCommandAck =: []
       <+> fldDispatch =: Dispatch [] st Nothing
       <+> fldRaidDevices =: []
       <+> fldM0 =: Nothing
       <+> fldNodeJob =: Nothing

    showLocality = do
      hardware <- gets Local (^. rlens fldHardware . rfield)
      raidDevs <- gets Local (^. rlens fldRaidDevices . rfield)
      m0 <- gets Local (^. rlens fldM0 . rfield)
      Log.actLog "locality" [ ("hardware", show hardware)
                            , ("raid devices", show raidDevs)
                            , ("mero objects", show $ (M0.showFid *** M0.showFid) <$> m0)
                            ]

    ourJob (JobFinished lis v) _ ls = case getField $ rget fldNodeJob ls of
      Just l | l `elem` lis -> return $ Just v
      _ -> return Nothing
