{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DoAndIfThenElse       #-}
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
import Data.Maybe (mapMaybe)
import Data.Text (Text, pack)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.CEP

-- | Event sent when to many failures has been sent for a 'Disk'.
data ResetAttempt = ResetAttempt StorageDevice UUID
  deriving (Eq, Generic, Show, Typeable)

instance Binary ResetAttempt

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
    mapMaybe extractPath $ ids
  where
    ids = G.connectedTo sd Has g
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | When the number of reset attempts is greater than this threshold, a 'Disk'
--   should be in 'DiskFailure' status.
resetAttemptThreshold :: Int
resetAttemptThreshold = 10

-- | Time to allow for SSPL to reply.
ssplTimeout :: Int
ssplTimeout = 1

-- | States of the Timeout rule.OB
data TimeoutState = TimeoutNormal | ResetAttemptSent

onCommandAck :: (Text -> NodeCmd)
           -> HAEvent CommandAck
           -> g
           -> Maybe (StorageDevice, String, UUID)
           -> Process (Maybe CommandAck)
onCommandAck _ _ _ Nothing = return Nothing
onCommandAck k (HAEvent _ cmd _) _ (Just (_, path, _)) =
  case commandAckType cmd of
    Just x | (k . pack $ path) == x -> return $ Just cmd
           | otherwise      -> return Nothing
    _ -> return Nothing

onSmartSuccess :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, String, UUID)
               -> Process (Maybe ())
onSmartSuccess (HAEvent _ cmd _) _ (Just (_, path, _)) =
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
               -> Maybe (StorageDevice, String, UUID)
               -> Process (Maybe (Maybe Text))
onSmartFailure (HAEvent _ cmd _) _ (Just (_, path, _)) =
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
    defineSimple "mero-note-set" $ \(HAEvent uid (Set ns) _) ->
      for_ ns $ \(Note mfid tpe) ->
        case tpe of
          M0_NC_FAILED -> do
            sdevm <- lookupConfObjByFid mfid
            for_ sdevm $ \m0sdev -> do
              mdev <- lookupSDevDisk m0sdev
              msdev <- lookupStorageDevice m0sdev
              case (mdev, msdev) of
                (Just dev, Just sdev) -> do
                  ongoing <- hasOngoingReset sdev
                  when (not ongoing) $ do
                    ratt <- getDiskResetAttempts sdev
                    let status = if ratt <= resetAttemptThreshold
                                 then M0_NC_TRANSIENT
                                 else M0_NC_FAILED
                    notifyMero [AnyConfObj m0sdev] status

                    when (status == M0_NC_FAILED) $ do
                      nid <- liftProcess getSelfNode
                      diskids <- findStorageDeviceIdentifiers sdev
                      let iem = InterestingEventMessage . pack . unwords $ [
                                    "M0_NC_FAILED reported."
                                  , "fid=" ++ show mfid
                                ] ++ map show diskids
                      sendInterestingEvent nid iem
                      pools <- getPools dev
                      traverse_ (startRepairOperation dev) pools

                    when (status == M0_NC_TRANSIENT) $ do
                      markOnGoingReset sdev
                      liftProcess $ do
                        self <- getSelfPid
                        usend self $ ResetAttempt sdev uid
                _ -> do
                  phaseLog "warning" $ "Cannot find all entities attached to M0"
                                    ++ " storage device: "
                                    ++ show m0sdev
                                    ++ ": "
                                    ++ show (mdev, msdev)
          _ -> return ()
#endif

    define "reset-attempt" $ do
      home         <- phaseHandle "home"
      down         <- phaseHandle "powerdown"
      downComplete <- phaseHandle "powerdown-complete"
      on           <- phaseHandle "poweron"
      onComplete   <- phaseHandle "poweron-complete"
      smart        <- phaseHandle "smart"
      smartSuccess <- phaseHandle "smart-success"
      smartFailure <- phaseHandle "smart-failure"
      end          <- phaseHandle "end"

      setPhase home $ \(ResetAttempt sdev uid) -> fork NoBuffer $ do
        paths <- lookupStorageDevicePaths sdev
        case paths of
          path:_ -> do
            put Local (Just (sdev, path, uid))
            unlessM (isStorageDevicePowered sdev) $
              continue on
            whenM (isStorageDeviceRunningSmartTest sdev) $
              switch [smartSuccess, smartFailure, timeout ssplTimeout down]
            continue down
          [] -> do
            phaseLog "warning" $ "Cannot perform reset attempt for drive "
                              ++ show sdev
                              ++ " as it has no device paths associated."
            messageProcessed uid

      directly down $ do
        Just (sdev, path, _) <- get Local
        nid <- liftProcess getSelfNode
        i <- getDiskPowerOffAttempts sdev
        if i <= resetAttemptThreshold
        then do
          incrDiskPowerOffAttempts sdev
          sendNodeCmd nid Nothing (DrivePowerdown $ pack path)
          switch [downComplete, timeout ssplTimeout down]
        else do
          markResetComplete sdev
#ifdef USE_MERO
          sd <- lookupStorageDeviceSDev sdev
          forM_ sd $ \m0sdev ->
            notifyMero [AnyConfObj m0sdev] M0_NC_FAILED
#endif
          continue end

      setPhaseIf downComplete (onCommandAck DrivePowerdown) $ \_ -> do
        Just (sdev, _, _) <- get Local
        markDiskPowerOff sdev
        continue on

      directly on $ do
        Just (sdev, path, _) <- get Local
        nid <- liftProcess getSelfNode
        i <- getDiskPowerOnAttempts sdev
        if i <= resetAttemptThreshold
        then do
          incrDiskPowerOnAttempts sdev
          sendNodeCmd nid Nothing (DrivePoweron $ pack path)
          switch [onComplete, timeout ssplTimeout on]
        else do
          markResetComplete sdev
#ifdef USE_MERO
          sd <- lookupStorageDeviceSDev sdev
          forM_ sd $ \m0sdev ->
            notifyMero [AnyConfObj m0sdev] M0_NC_FAILED
#endif
          continue end

      setPhaseIf onComplete (onCommandAck DrivePoweron) $ \_ -> do
        nid <- liftProcess getSelfNode
        Just (sdev, path, _) <- get Local
        markDiskPowerOn sdev
        incrDiskResetAttempts sdev
        markSMARTTestIsRunning sdev
        sendNodeCmd nid Nothing (SmartTest $ pack path)
        continue smart

      directly smart $ switch
        [smartSuccess, smartFailure, timeout ssplTimeout down]

      setPhaseIf smartSuccess onSmartSuccess $ \_ -> do
        Just (sdev, _, _) <- get Local
        markResetComplete sdev
        markSMARTTestComplete sdev
        markResetComplete sdev
#ifdef USE_MERO
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          notifyMero [AnyConfObj m0sdev] M0_NC_ONLINE
#endif
        continue end

      setPhaseIf smartFailure onSmartFailure $ \_ -> do
        Just (sdev, _, _) <- get Local
        markResetComplete sdev
        markSMARTTestComplete sdev
        markResetComplete sdev
#ifdef USE_MERO
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          notifyMero [AnyConfObj m0sdev] M0_NC_FAILED
#endif
        continue end

      directly end $ do
        Just (sdev, _, uid) <- get Local
        setDiskPowerOffAttempts sdev 0
        setDiskPowerOnAttempts sdev 0
        messageProcessed uid
        stop

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
