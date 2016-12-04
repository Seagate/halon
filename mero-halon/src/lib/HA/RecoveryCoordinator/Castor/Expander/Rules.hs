-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module rules for expander card.
--

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
module HA.RecoveryCoordinator.Castor.Expander.Rules
  ( rules ) where

import HA.EventQueue.Types
import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.RC.Actions.Dispatch
import HA.RecoveryCoordinator.Castor.Cluster.Events (StopProcessesRequest(..))
import HA.RecoveryCoordinator.Actions.Mero (getNodeProcesses)
import HA.RecoveryCoordinator.Mero.Actions.Conf
import HA.RecoveryCoordinator.Mero.Events (AnyStateChange)
import HA.RecoveryCoordinator.Mero.Transitions
import HA.RecoveryCoordinator.Castor.Drive.Events (ExpanderReset(..))
import HA.RecoveryCoordinator.Mero.State
import HA.RecoveryCoordinator.Castor.Node.Rules
  ( StartProcessesOnNodeResult(..)
  , StartProcessesOnNodeRequest(..)
  )
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Services.SSPL.CEP (sendNodeCmd)
import HA.Services.SSPL.LL.RC.Actions
  ( fldCommandAck
  , mkDispatchAwaitCommandAck
  )
import HA.Services.SSPL.LL.Resources
  ( NodeCmd(..)
  , RaidCmd(..)
  )

import Control.Distributed.Process (liftIO)
import Control.Lens
import Control.Monad (forM_)
import Control.Monad.Trans.Maybe

import Data.List (nub)
import Data.Maybe (isJust, listToMaybe, mapMaybe)
import Data.Proxy
import Data.UUID.V4 (nextRandom)
import qualified Data.Text as T
import Data.Vinyl

import Network.CEP

import Text.Printf (printf)

-- | How long to wait for notification from Mero/SSPL
notificationTimeout :: Int
notificationTimeout = 180 -- seconds

-- | How long to wait for the node to come up again
nodeUpTimeout :: Int
nodeUpTimeout = 460 -- seconds

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
      mero_notify_done <- phaseHandle "mero_notify_done"
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
      sspl_notify_done <- mkDispatchAwaitCommandAck dispatcher failed showLocality

      let defaultState = args expander_reset_evt

      setPhase expander_reset_evt $ \(HAEvent eid (ExpanderReset enc)) -> do
        put Local defaultState -- HALON-576, HALON-577
        todo eid

        mm0 <- runMaybeT $ do
          m0enc <- MaybeT $ getLocalGraph <&> encToM0Enc enc
          m0node <- MaybeT $ getLocalGraph <&> \rg -> listToMaybe
            [ node | ctrl <- G.connectedTo m0enc M0.IsParentOf rg :: [M0.Controller]
                   , Just node <- [G.connectedFrom M0.IsOnHardware ctrl rg]
                   ]
          return (m0enc, m0node)
        mnode <- getLocalGraph <&> \rg -> listToMaybe
          [ (host, node)
          | host <- G.connectedTo enc R.Has rg :: [R.Host]
          , node <- G.connectedTo host R.Runs rg
          ]
        raidDevs <- getLocalGraph <&> \rg -> let
            extractRaidDev (R.DIRaidDevice x) = Just x
            extractRaidDev _ = Nothing
          in nub $ mapMaybe extractRaidDev [
              lbl | d <- G.connectedTo enc R.Has rg :: [R.StorageDevice]
                  , lbl <- G.connectedTo d R.Has rg :: [R.DeviceIdentifier]
                  ]

        -- If we don't have the node, we can't do much, but it is valid
        -- that we might not have to deal with Mero (this can happen on the
        -- CMU), so we have to deal with that.
        case (mnode, raidDevs) of
          (Just (host, node@(R.Node nid)), (_:_)) -> do
            modify Local $ rlens fldHardware . rfield .~ Just (enc, host, node)
            modify Local $ rlens fldUUID . rfield .~ (Just eid)
            modify Local $ rlens fldRaidDevices . rfield .~ raidDevs

            -- Mark that the host is undergoing RAID reassembly
            modifyGraph $ G.connect host R.Is R.ReassemblingRaid

            -- Set default jump parameters. If no Mero, just stop RAID directly
            onSuccess stop_raid
            onTimeout notificationTimeout notify_failed

            -- Mark enclosure as transiently failed. This should cascade down to
            -- controllers, disks etc.
            forM_ mm0 $ \(m0enc, m0node) -> let
                notifications = [ stateSet m0enc enclosureTransient ]
                notificationChk = anyStateToAscPred <$> notifications
              in do
                applyStateChanges notifications
                modify Local $ rlens fldNotifications . rfield .~ Just notificationChk
                modify Local $ rlens fldM0 . rfield .~ Just (m0enc, m0node)
                -- Wait for Mero notification, and also jump to stop_mero_services
                waitFor mero_notify_done
                onSuccess stop_mero_services

            showLocality

            -- Tell SSPL to disable swap
            cmdUUID <- liftIO $ nextRandom
            sent <- sendNodeCmd nid (Just cmdUUID) $ SwapEnable False

            if sent
            then do
              modify Local $ rlens fldCommandAck . rfield .~ [cmdUUID]
              waitFor sspl_notify_done
              continue dispatcher
            else do
              -- TODO Send some kind of 'CannotTalkToSSPL' message
              phaseLog "error" $ "Expander reset event received for enclosure, "
                              ++ "but we are unable to contact SSPL on that "
                              ++ "node."
              continue failed
          (_, []) -> do
            phaseLog "info" $ "Expander reset event received for enclosure "
                           ++ "but there were no RAID devices to reassemble."
            done eid
          (Nothing, _) -> do
            -- TODO this is pretty interesting - should we raise an IEM?
            phaseLog "warning" $ "Expander reset event received for enclosure, "
                              ++ "but there was no corresponding node."
            done eid

      setPhaseAllNotifiedBy mero_notify_done
                            (rlens fldNotifications . rfield) $ do
        phaseLog "debug" "Mero notification complete"
        modify Local $ rlens fldNotifications . rfield .~ Nothing
        waitDone mero_notify_done
        continue dispatcher

      directly stop_mero_services $ do
        showLocality
        Just (_, _, node) <- gets Local (^. rlens fldHardware . rfield)
        Just (_, m0node) <- gets Local (^. rlens fldM0 . rfield)

        rg <- getLocalGraph
        -- TODO What if there are starting services? In other states?
        let procs = [ p | p <- getNodeProcesses node rg
                        , G.isConnected p R.Is M0.PSOnline rg
                        ]

        case procs of
          [] -> do
            phaseLog "info" $ "No mero processes on node."
            continue unmount
          _ -> do
            phaseLog "info" $ "Stopping the following processes: "
                            ++ (show procs)
            -- TODO stop processes with more gentle+violent means?
            -- e.g. first try `Spiel.processStop`, then systemd,
            -- then kill -9. Maybe `processQuiesce`? HALON-374
            promulgateRC $ StopProcessesRequest m0node procs
            let notifications = (\p -> ascPred p $ \case
                                     M0.PSOffline -> True
                                     M0.PSFailed{} -> True
                                     _ -> False) <$> procs

            modify Local $ rlens fldNotifications . rfield .~ Just notifications
            waitFor mero_notify_done
            onSuccess unmount
            continue dispatcher

      directly unmount $ do
        showLocality
        Just (_, _, R.Node nid) <- gets Local (^. rlens fldHardware . rfield)
        cmdUUID <- liftIO $ nextRandom
        -- TODO magic constant
        sent <- sendNodeCmd nid (Just cmdUUID) $ Unmount "/var/mero"

        if sent
        then do
          modify Local $ rlens fldCommandAck . rfield .~ [cmdUUID]
          waitFor sspl_notify_done
          onSuccess stop_raid

          continue dispatcher
        else do
          phaseLog "error" $ "Expander reset event received for enclosure "
                          ++ ", but we are unable to contact SSPL on that "
                          ++ "node."
          continue failed

      directly stop_raid $ do
        showLocality
        Just (_, _, R.Node nid) <- gets Local (^. rlens fldHardware . rfield)
        raidDevs <- gets Local (^. rlens fldRaidDevices . rfield)

        forM_ raidDevs $ \dev -> do
          cmdUUID <- liftIO $ nextRandom
          sent <- sendNodeCmd nid (Just cmdUUID)
                  $ NodeRaidCmd (T.pack dev) RaidStop

          if sent
          then
            modify Local $ rlens fldCommandAck . rfield %~ (cmdUUID :)
          else do
            phaseLog "warning" $ "Tried to stop RAID device "
                              ++ (show dev)
                              ++ ", but we are unable to contact SSPL on that "
                              ++ "node."

        waitFor sspl_notify_done
        onSuccess reassemble_raid

        continue dispatcher

      directly reassemble_raid $ do
        showLocality
        Just (_, _, R.Node nid) <- gets Local (^. rlens fldHardware . rfield)
        cmdUUID <- liftIO $ nextRandom
        sent <- sendNodeCmd nid (Just cmdUUID) $ NodeRaidCmd "--scan" (RaidAssemble [])

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
          phaseLog "warning" $ "Tried to reassemble RAID devices"
                            ++ ", but we are unable to contact SSPL on that "
                            ++ "node."
          continue failed

      directly start_mero_services $ do
        showLocality
        (Just (_, m0node)) <- gets Local (^. rlens fldM0 . rfield)
        promulgateRC $ StartProcessesOnNodeRequest m0node
        switch [mero_services_started, timeout nodeUpTimeout failed]

      setPhaseIf mero_services_started onNode $ \nr -> do
        phaseLog "debug" $ show nr
        case nr of
          NodeProcessesStarted{} -> continue mark_mero_healthy
          NodeProcessesStartTimeout{} -> continue nodeup_timeout
          NodeProcessesStartFailure{} -> do
            showLocality
            phaseLog "error" $ "Cannot start kernel, although it was never "
                            ++ "stopped."
            continue failed

      -- Mark the enclosure as healthy again
      directly mark_mero_healthy $ do
        Just (m0enc, _) <- gets Local (^. rlens fldM0 . rfield)
        let notifications = [ stateSet m0enc enclosureOnline ]
            notificationChk = anyStateToAscPred <$> notifications
        applyStateChanges notifications

        modify Local $ rlens fldNotifications . rfield .~ Just notificationChk
        waitFor mero_notify_done
        onSuccess finish

        continue dispatcher

      directly finish $ do
        showLocality
        phaseLog "info" $ "Raid reassembly complete."
        continue tidyup

      directly notify_failed $ do
        showLocality
        waiting <- gets Local (^. rlens fldDispatch . rfield . waitPhases)
        phaseLog "error" $ "Timeout whilst waiting for phases: "
                        ++ show waiting
        continue failed

      directly nodeup_timeout $ do
        showLocality
        phaseLog "error" $ "Timeout whilst waiting for Mero processes to "
                        ++ "restart."
        continue failed

      directly failed $ do
        showLocality
        phaseLog "error" $ "Error during expander reset handling."
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
        done uuid

      startFork expander_reset_evt defaultState

  where
    -- Enclosure, node
    fldHardware :: Proxy '("hardware", Maybe (R.Enclosure, R.Host, R.Node))
    fldHardware = Proxy
    -- Notifications to wait for
    fldNotifications :: Proxy '("notifications", Maybe [AnyStateChange -> Bool])
    fldNotifications = Proxy
    -- RAID devices
    fldRaidDevices :: Proxy '("raidDevices", [String])
    fldRaidDevices = Proxy
    -- Using Mero?
    fldM0 :: Proxy '("meroStuff", Maybe (M0.Enclosure, M0.Node))
    fldM0 = Proxy

    args st = fldHardware =: Nothing
       <+> fldNotifications =: Nothing
       <+> fldUUID =: Nothing
       <+> fldCommandAck =: []
       <+> fldDispatch =: Dispatch [] st Nothing
       <+> fldRaidDevices =: []
       <+> fldM0 =: Nothing
       <+> RNil

    showLocality = do
      hardware <- gets Local (^. rlens fldHardware . rfield)
      raidDevs <- gets Local (^. rlens fldRaidDevices . rfield)
      m0 <- gets Local (^. rlens fldM0 . rfield)
      phaseLog "locality"
        $ printf "Hardware: %s, Raid Devices: %s, Mero Objects: %s"
            (show hardware) (show raidDevs)
            (show $ (\(a,b) -> (M0.showFid a, M0.showFid b)) <$> m0)

    onNode x _ l = case (l ^. rlens fldM0 . rfield) of
        Just (_, m0node) | nodeOf x == m0node -> return $ Just x
          where
            nodeOf (NodeProcessesStarted n) = n
            nodeOf (NodeProcessesStartTimeout n _) = n
            nodeOf (NodeProcessesStartFailure n _) = n
        _ -> return Nothing
