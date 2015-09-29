{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to Castor install of Mero.

module HA.RecoveryCoordinator.Rules.Castor where

import Control.Distributed.Process

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Mero
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
#ifdef USE_MERO
import HA.RecoveryCoordinator.Rules.Mero
import HA.Resources.Mero hiding (Process, Enclosure, Rack)
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Actions.Mero
import HA.Services.Mero

import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState

import Data.List (unfoldr)
#endif

import Control.Monad

import Data.Binary (Binary)
import Data.Foldable
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text, pack)

import Network.CEP

-- | Event sent when to many failures has been sent for a 'Disk'.
newtype ResetAttempt = ResetAttempt StorageDevice deriving (Eq, Show, Binary)

-- | Event sent when a ResetAttempt were successful.
newtype ResetSuccess =
    ResetSuccess StorageDevice
    deriving (Eq, Show, Binary)

-- | Event sent when a ResetAttempt failed.
newtype ResetFailure =
    ResetFailure StorageDevice
    deriving (Eq, Show, Binary)

lookupStorageDevicePathsInGraph :: StorageDevice -> G.Graph -> [String]
lookupStorageDevicePathsInGraph sd g =
    catMaybes . map extractPath $ ids
  where
    ids = G.connectedTo sd Has g
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | When the number of reset attempts is greater than this threshold, a 'Disk'
--   should be in 'DiskFailure' status.
resetAttemptThreshold :: Int
resetAttemptThreshold = 10

-- | States of the Timeout rule.OB
data TimeoutState = TimeoutNormal | ResetAttemptSent

onCommandAck :: (Text -> NodeCmd)
           -> HAEvent CommandAck
           -> g
           -> Maybe (StorageDevice, String)
           -> Process (Maybe CommandAck)
onCommandAck _ _ _ Nothing = return Nothing
onCommandAck k (HAEvent _ cmd _) _ (Just (sdev, path)) =
  case commandAckType cmd of
    Just x | (k . pack $ path) == x -> return $ Just cmd
           | otherwise      -> return Nothing
    _ -> return Nothing

onSmartSuccess :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, String)
               -> Process (Maybe ())
onSmartSuccess (HAEvent _ cmd _) _ (Just (_, path)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | pack path == x ->
          case commandAck cmd of
            AckReplyPassed -> return $ Just ()
            _              -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartSuccess _ _ _ = return Nothing

onSmartFailure :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, String)
               -> Process (Maybe (Maybe Text))
onSmartFailure (HAEvent _ cmd _) _ (Just (_, path)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | pack path == x ->
          case commandAck cmd of
            AckReplyFailed  -> return $ Just Nothing
            AckReplyError e -> return $ Just $ Just e
            _               -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartFailure _ _ _ = return Nothing

castorRules :: Definitions LoopState ()
castorRules = do
    defineSimple "Initial-data-load" $ \(HAEvent eid CI.InitialData{..} _) -> do
      mapM_ goRack id_racks
#ifdef USE_MERO
      filesystem <- initialiseConfInRG
      loadMeroGlobals id_m0_globals
      loadMeroServers filesystem id_m0_servers
      failureSets <- generateFailureSets 0 1 0 -- TODO real values
      let chunks = flip unfoldr failureSets $ \xs ->
            case xs of
              [] -> Nothing
              _  -> Just $ splitAt 50 xs
      forM_ chunks $ \chunk -> do
        createPoolVersions filesystem chunk
        syncGraph
#endif
      liftProcess $ say "Loaded initial data"
      messageProcessed eid

#ifdef USE_MERO
    defineSimple "mero-note-set" $ \(Set ns) ->
      for_ ns $ \(Note mfid tpe) ->
        case tpe of
          M0_NC_FAILED -> do
            sdevm <- lookupConfObjByFid mfid
            for_ sdevm $ \m0sdev -> do
              dev <- getSDevDisk m0sdev
              sdev <- getStorageDevice m0sdev
              ongoing <- hasOngoingReset sdev
              when (not ongoing) $ do
                ratt <- getDiskResetAttempts sdev
                let status = if ratt <= resetAttemptThreshold
                             then M0_NC_TRANSIENT
                             else M0_NC_FAILED
                notifyMero [AnyConfObj m0sdev] status

                when (status == M0_NC_FAILED) $ do
                  nid <- liftProcess getSelfNode
                  let iem = InterestingEventMessage "m0_nc_failed"
                  sendInterestingEvent nid iem
                  pools <- getPools dev
                  traverse_ (startRepairOperation dev) pools

                when (status == M0_NC_TRANSIENT) $ do
                  markOnGoingReset sdev
                  liftProcess $ do
                    self <- getSelfPid
                    usend self $ ResetAttempt sdev
          _ -> return ()
#endif

    define "reset-attempt" $ do
      home         <- phaseHandle "home"
      down         <- phaseHandle "powerdown"
      on           <- phaseHandle "poweron"
      smart        <- phaseHandle "smart"
      smartSuccess <- phaseHandle "smart-success"
      smartFailure <- phaseHandle "smart-failure"

      setPhase home $ \(ResetAttempt sdev) -> fork NoBuffer $ do
        nid <- liftProcess getSelfNode
        paths <- lookupStorageDevicePaths sdev
        case paths of
          path:_ -> do
            incrDiskPowerOffAttempts sdev
            sendNodeCmd nid Nothing (DrivePowerdown $ pack path)
            put Local (Just (sdev, path))
            continue down
          [] -> do
            phaseLog "warning" $ "Cannot perform reset attempt for drive "
                              ++ show sdev
                              ++ " as it has no device paths associated."

      setPhaseIf down (onCommandAck DrivePowerdown) $ \_ -> do
        Just (sdev, path) <- get Local
        nid <- liftProcess getSelfNode
        sendNodeCmd nid Nothing (DrivePoweron $ pack path)
        incrDiskPowerOnAttempts sdev
        markDiskPowerOff sdev
        continue on

      setPhaseIf on (onCommandAck DrivePoweron) $ \_ -> do
        nid <- liftProcess getSelfNode
        Just (sdev, path) <- get Local
        markDiskPowerOn sdev
        incrDiskResetAttempts sdev
        markSMARTTestIsRunning sdev
        sendNodeCmd nid Nothing (SmartTest $ pack path)
        continue smart

      directly smart $ switch [smartSuccess, smartFailure]

      setPhaseIf smartSuccess onSmartSuccess $ \_ -> do
        Just (sdev, path) <- get Local
        markResetComplete sdev
        markSMARTTestComplete sdev
        markResetComplete sdev
#ifdef USE_MERO
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          notifyMero [AnyConfObj m0sdev] M0_NC_ONLINE
#endif
        put Local Nothing

      setPhaseIf smartFailure onSmartFailure $ \_ -> do
        Just (sdev, path) <- get Local
        markResetComplete sdev
        markSMARTTestComplete sdev
        markResetComplete sdev
#ifdef USE_MERO
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          notifyMero [AnyConfObj m0sdev] M0_NC_FAILED
#endif
        put Local Nothing

      start home Nothing
  where
    goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
      registerRack rack
      mapM_ (goEnc rack) rack_enclosures
    goEnc rack (CI.Enclosure{..}) = let
        enclosure = Enclosure enc_id
      in do
        registerEnclosure rack enclosure
        mapM_ (registerBMC enclosure) enc_bmc
        mapM_ (goHost enclosure) enc_hosts
    goHost enc (CI.Host{..}) = let
        host = Host h_fqdn
        mem = fromIntegral h_memsize
        cpucount = fromIntegral h_cpucount
        attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount]
      in do
        registerHost host
        locateHostInEnclosure host enc
        mapM_ (setHostAttr host) attrs
        mapM_ (registerInterface host) h_interfaces
