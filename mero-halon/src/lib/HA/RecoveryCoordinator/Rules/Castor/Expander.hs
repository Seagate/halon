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
module HA.RecoveryCoordinator.Rules.Castor.Expander
  ( rules ) where

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero (getNodeProcesses)
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import HA.RecoveryCoordinator.Events.Castor.Cluster (StopProcessesRequest(..))
import HA.RecoveryCoordinator.Events.Drive (ExpanderReset(..))
import HA.RecoveryCoordinator.Rules.Mero.Conf
import HA.RecoveryCoordinator.Rules.Castor.Node
  ( StartProcessesOnNodeResult(..)
  , StartProcessesOnNodeRequest(..)
  )
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Services.Mero (m0d)
import HA.Services.Mero.CEP (meroChannel)
import HA.Services.SSPL.CEP (sendNodeCmd)
import HA.Services.SSPL.LL.Resources
  ( AckReply(..)
  , CommandAck(..)
  , NodeCmd(..)
  , RaidCmd(..)
  )

import Control.Distributed.Process (liftIO)
import Control.Lens
import Control.Monad (forM_, when)
import Control.Monad.Trans.Maybe

import Data.List (delete, nub)
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

-- | Holds dispatching information for complex jumps.
type FldDispatch = '("dispatch", Dispatch)
fldDispatch :: Proxy FldDispatch
fldDispatch = Proxy

data Dispatch = Dispatch {
    _waitPhases :: [Jump PhaseHandle]
  , _successPhase :: Jump PhaseHandle
  , _timeoutPhase :: Maybe (Int, Jump PhaseHandle)
}
makeLenses ''Dispatch

-- | Pass control back to central dispatcher
onSuccess :: forall l. (FldDispatch ∈ l)
          => Jump PhaseHandle
          -> PhaseM LoopState (FieldRec l) ()
onSuccess next =
  modify Local $ rlens fldDispatch . rfield . successPhase .~ next

-- | Add a phase to wait for
waitFor :: forall l. (FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM LoopState (FieldRec l) ()
waitFor p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (p :)

-- | Announce that this phase has finished waiting and remove from dispatch.
waitDone :: forall l. (FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM LoopState (FieldRec l) ()
waitDone p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (delete p)

mkDispatcher :: forall l. (FldDispatch ∈ l)
             => RuleM LoopState (FieldRec l) (Jump PhaseHandle)
mkDispatcher = do
  dispatcher <- phaseHandle "dispatcher::dispatcher"

  directly dispatcher $ do
    dinfo <- gets Local (^. rlens fldDispatch . rfield)
    phaseLog "dispatcher:awaiting" $ show (dinfo ^. waitPhases)
    phaseLog "dispatcher:onSuccess" $ show (dinfo ^. successPhase)
    phaseLog "dispatcher:onTimeout" $ show (dinfo ^. timeoutPhase)
    case dinfo ^. waitPhases of
      [] -> continue $ dinfo ^. successPhase
      xs -> switch (xs ++ (maybe [] ((:[]) . uncurry timeout)
                                    $ dinfo ^. timeoutPhase))

  return dispatcher

rules :: Definitions LoopState ()
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
ruleReassembleRaid :: Definitions LoopState ()
ruleReassembleRaid =
    define "castor::expander::reassembleRaid" $ do
      expander_reset_evt <- phaseHandle "expander_reset_evt"
      mero_notify_done <- phaseHandle "mero_notify_done"
      sspl_notify_done <- phaseHandle "sspl_notify_done"
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

      setPhase expander_reset_evt $ \(HAEvent eid (ExpanderReset enc) _) -> do

        todo eid

        mm0 <- runMaybeT $ do
          m0enc <- MaybeT $ getLocalGraph <&> listToMaybe . encToM0Enc enc
          m0node <- MaybeT $ getLocalGraph <&> \rg -> listToMaybe
            [ node | ctrl <- G.connectedTo m0enc M0.IsParentOf rg :: [M0.Controller]
                   , node <- G.connectedFrom M0.IsOnHardware ctrl rg
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
            modify Local $ rlens fldDispatch . rfield .~
              Dispatch [] stop_raid (Just (notificationTimeout, notify_failed))

            -- Mark enclosure as transiently failed. This should cascade down to
            -- controllers, disks etc.
            forM_ mm0 $ \(m0enc, m0node) -> let
                notifications = [ stateSet m0enc M0.M0_NC_TRANSIENT ]
              in do
                applyStateChanges notifications
                modify Local $ rlens fldNotifications . rfield .~ Just notifications
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
              phaseLog "error" $ "Expander reset event received for enclosure, "
                              ++ "but we are unable to contact SSPL on that "
                              ++ "node."
              continue failed
          (_, []) -> do
            phaseLog "info" $ "Expander reset event received for enclosure "
                           ++ "but there were no RAID devices to reassemble."
            done eid
          (Nothing, _) -> do
            phaseLog "warning" $ "Expander reset event received for enclosure, "
                              ++ "but there was no corresponding node."
            done eid

      setPhaseAllNotified mero_notify_done
                          (rlens fldNotifications . rfield) $ do
        phaseLog "debug" "Mero notification complete"
        modify Local $ rlens fldNotifications . rfield .~ Nothing
        waitDone mero_notify_done
        continue dispatcher

      setPhaseIf sspl_notify_done onCommandAck $ \(eid, uid, ack) -> do
        phaseLog "debug" "SSPL notification complete"
        showLocality
        modify Local $ rlens fldCommandAck . rfield %~ (delete uid)
        messageProcessed eid
        remaining <- gets Local (^. rlens fldCommandAck . rfield)
        when (null remaining) $ waitDone sspl_notify_done

        phaseLog "info" $ "SSPL ack for command "  ++ show (commandAckType ack)
        case commandAck ack of
          AckReplyPassed -> do
            phaseLog "info" $ "SSPL command successful."
            continue dispatcher
          AckReplyFailed -> do
            phaseLog "warning" $ "SSPL command failed."
            continue dispatcher
          AckReplyError msg -> do
            phaseLog "error" $ "Error received from SSPL: " ++ (T.unpack msg)
            continue failed

      directly stop_mero_services $ do
        showLocality
        Just (_, _, node) <- gets Local (^. rlens fldHardware . rfield)
        Just (_, m0node) <- gets Local (^. rlens fldM0 . rfield)

        rg <- getLocalGraph
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
            promulgateRC $ StopProcessesRequest m0node procs
            let notifications = (\p -> stateSet p M0.PSOffline) <$> procs
            modify Local $ rlens fldNotifications . rfield .~ (Just notifications)
            waitFor mero_notify_done
            onSuccess unmount
            continue dispatcher

      directly unmount $ do
        showLocality
        Just (_, _, R.Node nid) <- gets Local (^. rlens fldHardware . rfield)
        cmdUUID <- liftIO $ nextRandom
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
          NodeProcessesStarted _ -> continue mark_mero_healthy
          NodeProcessesStartTimeout _ -> continue nodeup_timeout
          NodeProcessesStartFailure _ -> do
            showLocality
            phaseLog "error" $ "Cannot start kernel, although it was never "
                            ++ "stopped."
            continue failed

      -- Mark the enclosure as healthy again
      directly mark_mero_healthy $ do
        Just (m0enc, _) <- gets Local (^. rlens fldM0 . rfield)
        let notifications = [ stateSet m0enc M0.M0_NC_ONLINE ]
        applyStateChanges notifications

        modify Local $ rlens fldNotifications . rfield .~ (Just notifications)
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

      startFork expander_reset_evt (args expander_reset_evt)

  where
    -- Enclosure, node
    fldHardware :: Proxy '("hardware", Maybe (R.Enclosure, R.Host, R.Node))
    fldHardware = Proxy
    -- Notifications to wait for
    fldNotifications :: Proxy '("notifications", Maybe [AnyStateSet])
    fldNotifications = Proxy
    -- Command acknowledgements to wait for
    fldCommandAck :: Proxy '("spplCommandAck", [UUID])
    fldCommandAck = Proxy
    -- Message UUID
    fldUUID :: Proxy '("uuid", Maybe UUID)
    fldUUID = Proxy
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

    -- SSPL command acknowledgement
    onCommandAck (HAEvent eid cmd _) _ l =
      case (l ^. rlens fldCommandAck . rfield, commandAckUUID cmd) of
        (xs, Just y) | y `elem` xs -> return $ Just (eid, y, cmd)
        _ -> return Nothing
    onNode x _ l = case (l ^. rlens fldM0 . rfield) of
        Just (_, m0node) | nodeOf x == m0node -> return $ Just x
          where
            nodeOf (NodeProcessesStarted n) = n
            nodeOf (NodeProcessesStartTimeout n) = n
            nodeOf (NodeProcessesStartFailure n) = n
        _ -> return Nothing
