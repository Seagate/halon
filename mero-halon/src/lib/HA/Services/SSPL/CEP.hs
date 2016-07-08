-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE CPP                 #-}

module HA.Services.SSPL.CEP where

import HA.EventQueue.Types (HAEvent(..))
import HA.Service hiding (configDict)
import HA.Services.SSPL.IEM
import HA.Services.SSPL.LL.Resources
import HA.RecoveryCoordinator.Mero

import HA.RecoveryCoordinator.Events.Drive
import HA.ResourceGraph
import HA.Resources (Cluster(..), Node(..), Has(..))
import HA.Resources.Castor
#ifdef USE_MERO
import HA.RecoveryCoordinator.Rules.Mero.Conf
import qualified HA.Resources.Mero as M0
import Mero.ConfC (strToFid)
import Mero.Notification
import Text.Read (readMaybe)
#endif

import SSPL.Bindings

import Control.Applicative
import Control.Arrow ((>>>))
import Control.Distributed.Process
  ( NodeId
  , SendPort
  , sendChan
  , say
  , usend
  )
import Control.Lens ((<&>))
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Maybe

import qualified Data.Aeson as Aeson
import Data.Maybe (catMaybes, listToMaybe, maybeToList, fromMaybe, isJust)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import Data.UUID (UUID)
import Data.Binary (Binary)
import Data.Typeable (Typeable)

import Network.CEP
import GHC.Generics

import Prelude hiding (mapM_)

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

sendInterestingEvent :: NodeId
                     -> InterestingEventMessage
                     -> PhaseM LoopState l ()
sendInterestingEvent nid msg = do
  phaseLog "action" $ "Sending InterestingEventMessage."
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp IEMChannel rg
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan msg
    _ -> phaseLog "warning" "Cannot find IEM channel!"

-- | Send command for system on remove node.
sendSystemdCmd :: NodeId
               -> SystemdCmd
               -> PhaseM LoopState l ()
sendSystemdCmd nid req = do
  phaseLog "action" $ "Sending Systemd request" ++ show req
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp CommandChannel rg
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan (Nothing :: Maybe UUID, makeSystemdMsg req)
    _ -> phaseLog "warning" "Cannot find systemd channel!"

-- | Send command to logger actuator.
sendLoggingCmd :: Host
               -> LoggerCmd
               -> PhaseM LoopState l ()
sendLoggingCmd host req = do
  phaseLog "action" $ "Sending Logger request" ++ show req
  rg <- getLocalGraph
  let mchan = listToMaybe $ do
        s    <- connectedTo Cluster Supports rg
        node <- connectedTo host Runs rg
        sp   <- maybeToList $ runningService (node::Node) (s::Service SSPLConf) rg
        connectedTo sp CommandChannel rg
  case mchan of
    Just (Channel chan) -> liftProcess $ sendChan chan (Nothing :: Maybe UUID, makeLoggerMsg req)
    _ -> phaseLog "error" "Cannot find sspl channel!"

mkDiskLoggingCmd :: T.Text -- ^ Status
                 -> T.Text -- ^ Serial Number
                 -> T.Text -- ^ Reason
                 -> LoggerCmd
mkDiskLoggingCmd st serial reason = LoggerCmd message "LOG_WARNING" "HDS" where
  message = "{'status': '" <> st <> "', 'reason': '" <> reason <> "', 'serial_number': '" <> serial <> "'}"


data DriveLedUpdate = DrivePermanentlyFailed -- ^ Drive is failed permanently
                    | DriveTransientlyFailed -- ^ Drive is beign reset or smart check
                    | DriveRebalancing       -- ^ Rebalance operation is happening on a drive
                    | DriveOk                -- ^ Drive is ok
                    deriving (Show)

sendLedUpdate :: DriveLedUpdate -> Host -> T.Text -> PhaseM LoopState l Bool
sendLedUpdate status host sn = do
  phaseLog "action" $ "Sending Led update " ++ show status ++ " about " ++ show sn ++ " on " ++ show host
  rg <- getLocalGraph
  let mnode = listToMaybe [ node
                          | s    <- connectedTo Cluster Supports rg
                          , node <- connectedTo host Runs rg
                          , isJust $ runningService (node :: Node) (s :: Service SSPLConf) rg
                          ]
  case mnode of
    Just (Node nid) -> case status of
      DrivePermanentlyFailed -> do
        sendNodeCmd nid Nothing (DriveLed sn FaultOn)
      DriveTransientlyFailed ->
        sendNodeCmd nid Nothing (DriveLed sn PulseFastOn)
      DriveRebalancing -> do
        sendNodeCmd nid Nothing (DriveLed sn PulseSlowOn)
      DriveOk -> do
        sendNodeCmd nid Nothing (DriveLed sn PulseSlowOff)
    _ -> do phaseLog "error" "Cannot find sspl service on the node!"
            return False


-- | Send command to nodecontroller. Reply will be received as a
-- HAEvent CommandAck. Where UUID will be set to UUID value if passed, and
-- any random value otherwise.
sendNodeCmd :: NodeId
            -> Maybe UUID
            -> NodeCmd
            -> PhaseM LoopState l Bool
sendNodeCmd nid muuid req = do
  phaseLog "action" $ "Sending node actuator request: " ++ show req
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp CommandChannel rg
  case chanm of
    Just (Channel chan) -> do liftProcess $ sendChan chan (muuid, makeNodeMsg req)
                              return True
    _ -> do phaseLog "warning" "Cannot find command channel!"
            return False

registerChannels :: ServiceProcess SSPLConf
                 -> ActuatorChannels
                 -> PhaseM LoopState l ()
registerChannels svc acs = modifyLocalGraph $ \rg -> do
    phaseLog "rg" "Registering SSPL actuator channels."
    let rg' =   registerChannel IEMChannel (iemPort acs)
            >>> registerChannel CommandChannel (systemdPort acs)
            $   rg
    return rg'
  where
    registerChannel :: forall r b. Relation r (ServiceProcess SSPLConf) (Channel b)
                    => r
                    -> SendPort b
                    -> Graph
                    -> Graph
    registerChannel r sp =
        newResource svc >>>
        newResource chan >>>
        connect svc r chan
      where
        chan = Channel sp

findActuationNode :: Configuration a => Service a
                  -> PhaseM LoopState l NodeId
findActuationNode sspl = do
    (Node actuationNode) <- fmap head
        $ findHosts ".*"
      >>= filterM (hasHostAttr HA_POWERED)
      >>= mapM nodesOnHost
      >>= return . join
      >>= filterM (\a -> isServiceRunning a sspl)
    return actuationNode

--------------------------------------------------------------------------------
-- Rules                                                                      --
--------------------------------------------------------------------------------

ssplRulesF :: Service SSPLConf -> Definitions LoopState ()
ssplRulesF sspl = sequence_
  [ ruleDeclareChannels
  , ruleMonitorDriveManager
  , ruleMonitorStatusHpi
  , ruleMonitorHostUpdate
  , ruleMonitorRaidData
  , ruleSystemdCmd sspl
  , ruleHlNodeCmd sspl
  , ruleThreadController
  , ruleSSPLTimeout sspl
  , ruleSSPLConnectFailure
  , ruleMonitorExpanderReset
#ifdef USE_MERO
  , ruleMonitorServiceRestart
#endif
  ]

ruleDeclareChannels :: Definitions LoopState ()
ruleDeclareChannels = defineSimple "declare-channels" $
      \(HAEvent uuid (DeclareChannels pid svc acs) _) -> do
          registerChannels svc acs
          ack pid
          messageProcessed uuid

data RuleDriveManagerDisk = RuleDriveManagerDisk StorageDevice
  deriving (Eq,Show,Generic,Typeable)

instance Binary RuleDriveManagerDisk

-- | SSPL Monitor drivemanager
ruleMonitorDriveManager :: Definitions LoopState ()
ruleMonitorDriveManager = define "monitor-drivemanager" $ do
   pinit  <- phaseHandle "init"
   pcommit <- phaseHandle "commit"

   setPhase pinit $ \(HAEvent uuid (nid, srdm) _) -> do
     let enc' = Enclosure . T.unpack
                          . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN
                          $ srdm
         diskNum = fromInteger $ sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum srdm
         sn = DISerialNumber . T.unpack
                . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerialNumber
                $ srdm
         path = DIPath . T.unpack
                . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerPathID
                $ srdm

     phaseLog "sspl-service" $ "monitor-drivemanager request received for drive: "
                            ++ (show [sn, path])
                            ++ " in enclosure "
                            ++ (show enc')

     -- If SSPL doesn't know which enclosure the drive in, try to
     -- infer it from the drive serial number and info we may have
     -- gotten previously
     enc <- case enc' of
       Enclosure "HPI_Data_Not_Available" -> lookupStorageDevicesWithDI sn >>= \case
         [] -> do
           phaseLog "warn" $ "No SD found with SN " ++ show sn
           return enc'
         sd : _ -> lookupEnclosureOfStorageDevice sd >>= \case
           Nothing -> do
             phaseLog "warn" $ "No enclosure found for " ++ show sd
             return enc'
           Just enc'' -> return enc''
       _ -> return enc'

     put Local $ Just (uuid, nid, enc, diskNum, srdm, sn, path)
     lookupStorageDeviceInEnclosure enc (DIIndexInEnclosure diskNum) >>= \case
       Nothing ->
         -- Try to check if we have device with known serial number, just without location.
         lookupStorageDeviceInEnclosure enc sn >>= \case
           Just disk -> do
             identifyStorageDevice disk [DIIndexInEnclosure diskNum, path]
             selfMessage (RuleDriveManagerDisk disk)
           Nothing -> do
             phaseLog "sspl-service"
                 $ "Cant find disk in " ++ show enc ++ " at " ++ show diskNum ++ " creating new entry."
             diskUUID <- liftIO $ nextRandom
             let disk = StorageDevice diskUUID
             locateStorageDeviceInEnclosure enc disk
             mhost <- findNodeHost (Node nid)
             forM_ mhost $ \host -> locateHostInEnclosure host enc
             identifyStorageDevice disk [DIIndexInEnclosure diskNum, sn, path]
             syncGraphProcess $ \self -> usend self (RuleDriveManagerDisk disk)
       Just st -> selfMessage (RuleDriveManagerDisk st)
     continue pcommit

   setPhase pcommit $ \(RuleDriveManagerDisk disk) -> do
     Just (uuid, nid, enc, _diskNum, srdm, _sn, _path) <- get Local
     let
      disk_status = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus srdm
      disk_reason = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskReason srdm

     oldDriveStatus <- maybe (StorageDeviceStatus "" "") id <$> driveStatus disk
     isOngoingReset <- hasOngoingReset disk
     isRemoved <- isStorageDriveRemoved disk

     if isOngoingReset || isRemoved
     then do
       phaseLog "info" $ unwords [
                            "Ignoring DriveManager updates for disk:"
                          , show disk
                          , "due to disk being"
                          , if isRemoved then "removed" else "reset"
                          ]
       messageProcessed uuid
     else
       case ( T.toUpper disk_status, T.toUpper disk_reason) of
        (s, r) | oldDriveStatus == StorageDeviceStatus (T.unpack s) (T.unpack r) ->
          messageProcessed uuid
        ("FAILED", "SMART") -> do
          updateDriveStatus disk (T.unpack disk_status) (T.unpack disk_reason)
          selfMessage $ DriveFailed uuid (Node nid) enc disk
        ("EMPTY", "NONE") -> do
          -- This is probably indicative of expander reset?
          updateDriveStatus disk (T.unpack disk_status) (T.unpack disk_reason)
          selfMessage $ DriveTransient uuid (Node nid) enc disk
        ("OK", "NONE") -> do
          -- Disk has returned to normal after expander reset?
          updateDriveStatus disk (T.unpack disk_status) (T.unpack disk_reason)
          selfMessage $ DriveOK uuid (Node nid) enc disk
        (s,r) -> let
            msg = InterestingEventMessage $ logSSPLUnknownMessage
                  ( "{'type': 'actuatorRequest.manager_status', "
                  <> "'reason': 'Error processing drive manager response: drive status "
                  <> s <> " reason " <> r <> " is not known'}"
                  )
          in do
            sendInterestingEvent nid msg
            messageProcessed uuid
   start pinit Nothing

-- | Handle information messages about drive changes from HPI system.
ruleMonitorStatusHpi :: Definitions LoopState ()
ruleMonitorStatusHpi = defineSimple "monitor-status-hpi" $ \(HAEvent uuid (nid, srphi) _) -> do
      let wwn = DIWWN . T.unpack
                      . sensorResponseMessageSensor_response_typeDisk_status_hpiWwn
                      $ srphi
          diskNum = fromInteger
                  . sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum
                  $ srphi
          idx = DIIndexInEnclosure diskNum
          serial_str = sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber
                     $ srphi
          serial = DISerialNumber . T.unpack $ serial_str
          enc   = Enclosure . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN
                       $ srphi
          is_powered = sensorResponseMessageSensor_response_typeDisk_status_hpiDiskPowered srphi
          is_installed = sensorResponseMessageSensor_response_typeDisk_status_hpiDiskInstalled srphi

      phaseLog "sspl-service" $ "monitor-hpi request received for drive:"
                             ++ show [wwn, idx, serial]
                             ++ " in enclosure "
                             ++ (show enc)

      existingByIdx <- lookupStorageDeviceInEnclosure enc idx
      existingBySerial <- lookupStorageDeviceInEnclosure enc serial

      sdev <- case (existingByIdx, existingBySerial) of
        (Just i, Just s) | i == s ->
          -- One existing device.
          return i
        (Just i, Just _) -> do
          -- Drive with this serial is known, but is not the drive in this slot.
          -- In this case the drive has probably been moved.
          void $ attachStorageDeviceReplacement i [serial, wwn, idx]
          return i
        (Just i, Nothing) -> do
          lookupStorageDeviceSerial i >>= \case
            [] -> do
              -- We have a device in this slot, but we don't know its serial.
              identifyStorageDevice i [serial, wwn]
            _ -> do
              -- We have a device in this slot, but it has the wrong serial.
              -- So this is probably a replacement.
              void $ attachStorageDeviceReplacement i [serial, wwn, idx]
          return i
        (Nothing, Just s) -> do
          -- We have a serial number for the device, but don't know its location.
          identifyStorageDevice s [idx, wwn]
          return s
        (Nothing, Nothing) -> do
          -- This is a completely new device to Halon
          diskUUID <- liftIO $ nextRandom
          let disk = StorageDevice diskUUID
          locateStorageDeviceInEnclosure enc disk
          identifyStorageDevice disk [idx]
          -- TODO Do we need to do this?
          void $ attachStorageDeviceReplacement disk [serial, wwn, idx]
          return disk

      -- Now find out whether we need to send removed or powered messages
      was_powered <- isStorageDevicePowered sdev
      was_removed <- isStorageDriveRemoved sdev
      isOngoingReset <- hasOngoingReset sdev

      phaseLog "debug" $ unwords [
          "was_installed:", show (not was_removed)
        , "is_installed:", show is_installed
        , "was_powered:", show was_powered
        , "is_powered:", show is_powered
        , "is_undergoing_reset:", show isOngoingReset
        ]
      more_needed <- case (is_installed, is_powered) of
       (True, _) | was_removed -> do
         selfMessage $ DriveInserted uuid sdev enc diskNum serial
         return True
       (False, _) | (not was_removed) -> do
         selfMessage $ DriveRemoved uuid (Node nid) enc sdev diskNum
         return True
       (_, True) | ((not isOngoingReset) && (not was_powered)) -> do
         selfMessage $ DrivePowerChange uuid (Node nid) enc sdev diskNum serial_str True
         return True
       (_, False) | (was_powered && (not isOngoingReset)) -> do
         selfMessage $ DrivePowerChange uuid (Node nid) enc sdev diskNum serial_str False
         return True
       _ -> return False

      if more_needed
      then syncGraph (return ())
      else syncGraphProcessMsg uuid

#ifdef USE_MERO
-- | Handle SSPL message about a service restart.
ruleMonitorServiceRestart :: Definitions LoopState ()
ruleMonitorServiceRestart = defineSimple "monitor-service-restart" $ \(HAEvent uuid (_ :: NodeId, watchdogmsg) _) -> do

  let currentState = sensorResponseMessageSensor_response_typeService_watchdogService_state watchdogmsg
      prevState = sensorResponseMessageSensor_response_typeService_watchdogPrevious_service_state watchdogmsg
      serviceName = sensorResponseMessageSensor_response_typeService_watchdogService_name watchdogmsg
      -- assume we have ‘service@fid.service’ format
      mprocessFid = strToFid . T.unpack . T.takeWhile (/= '.') . T.drop 1
                    $ T.dropWhile (/= '@') serviceName
      mcurrentPid = readMaybe . T.unpack
                    $ sensorResponseMessageSensor_response_typeService_watchdogPid watchdogmsg
      mpreviousPid = readMaybe . T.unpack
                     $ sensorResponseMessageSensor_response_typeService_watchdogPrevious_pid watchdogmsg

  when (currentState == "active" && prevState == "inactive") $ do
    phaseLog "info" $ "Received SSPL message about service restart: "
                   ++ show watchdogmsg

  case (,,,,) <$> mprocessFid <*> mcurrentPid <*> mpreviousPid <*> pure currentState <*> pure prevState of
    Nothing -> return ()
    _ | mpreviousPid == mcurrentPid -> phaseLog "warn" $
          "Previous and current PIDs are the same, ignoring message"
    Just (processFid, currentPid, previousPid, "active", "inactive") -> do
      svs <- M0.getM0Processes <$> getLocalGraph
      phaseLog "info" $ "Looking for fid " ++ show processFid ++ " in " ++ show svs
      let markStarting p = do
            phaseLog "info" $ "Marking " ++ show (M0.fid p) ++ " as starting."
            modifyLocalGraph $ return . connectUniqueFrom p Has (M0.PID currentPid)
            applyStateChanges [stateSet p M0.PSStarting]
      case listToMaybe $ filter (\p -> M0.r_fid p == processFid) svs of
        Nothing -> phaseLog "warn" $ "Couldn't find process with fid " ++ show processFid
        Just p -> do
          rg <- getLocalGraph
          case (listToMaybe $ connectedTo p Is rg, listToMaybe $ connectedTo p Has rg) of

            -- We have a running process with no PID somehow: for
            -- example all services went up, we marked process online
            -- but the mero notification for the process with its PID
            -- hasn't arrived yet. As SSPL is saying this process
            -- restarted (or started up first time), mark as starting
            -- and wait for mero to tell us when the process is ready.
            (Just M0.PSOnline, Nothing) -> do
              phaseLog "info" $ "SSPL restart notification for online process without PID"
              markStarting p

            -- We have a running process and the SSPL notification is
            -- for the corresponding PID. Do nothing, the process is
            -- OK.
            (Just M0.PSOnline, Just (M0.PID pid))
              | currentPid == pid -> return ()
            -- Current process is running but SSPL says it has
            -- restarted. Mark it as starting and wait for mero to
            -- tell us that it's online.
              | previousPid == pid -> do
                  phaseLog "warn" $ "Process restarted, SSPL notification received first."
                  markStarting p
            -- The message is not about current or past process, do nothing.
              | otherwise -> do
                  -- Warn because it's probably not gerat to have SSPL
                  -- messages this late/out of order.
                  phaseLog "warn" $ "Current process has PID" ++ show pid
                                 ++ " but we got a notification for "
                                 ++ show (previousPid, currentPid)

            -- Process starting with no PID, we were probably booting
            -- up first time.
            (Just M0.PSStarting, Nothing) -> markStarting p
            -- Process starting with pid: we have either received a
            -- message like this already and are waiting for online
            -- notification from mero or we have received an online
            -- notification from mero first and we're telling it to
            -- restart connections. In first case do nothing because
            -- duplicate message. In second case also do nothing
            -- because the same rule will transition the process into
            -- online by itself.
            (Just M0.PSStarting, Just (M0.PID pid)) | currentPid == pid -> return ()

            s -> phaseLog "warn" $
                 "Restart notification for process with state " ++ show s
    Just msg -> do
      phaseLog "info" $ "Process notification but not restarting: " ++ show msg
  messageProcessed uuid
#endif

-- | SSPL Monitor host_update
ruleMonitorHostUpdate :: Definitions LoopState ()
ruleMonitorHostUpdate = defineSimple "monitor-host-update" $ \(HAEvent uuid (nid, srhu) _) -> do
      let host = Host . T.unpack
                     $ sensorResponseMessageSensor_response_typeHost_updateHostId srhu
          node = Node nid
      registerHost host
      locateNodeOnHost node host
      phaseLog "rg" $ "Registered host: " ++ show host
      syncGraphProcessMsg uuid

-- | Monitor RAID data. We should register the RAID devices in the system,
--   with no corresponding Mero devices.
--   Raid messages from mdstat have a slightly unusual structure - we receive
--   the letter 'U' if the drive is part of the array and working, and
--   an underscore (_) if not.
ruleMonitorRaidData :: Definitions LoopState ()
ruleMonitorRaidData = define "monitor-raid-data" $ do

  raid_msg <- phaseHandle "raid_msg"
  reset_success <- phaseHandle "reset_success"
  reset_failure <- phaseHandle "reset_failure"
  end <- phaseHandle "end"

  setPhase raid_msg $ \(HAEvent uid (nid::NodeId, srrd) _) -> let
      device_t = sensorResponseMessageSensor_response_typeRaid_dataDevice srrd
      device = T.unpack device_t
      -- Drives should have min length 2, so it's OK to access these directly
      drives = sensorResponseMessageSensor_response_typeRaid_dataDrives srrd

    in do
      phaseLog "debug" "starting"
      todo uid
      mhost <- findNodeHost (Node nid)
      case mhost of
        Nothing -> phaseLog "error" $ "Cannot find host for node " ++ show nid
                                    ++ " resulting from failure of RAID device "
                                    ++ show device
        Just host -> do
          phaseLog "debug" $ "Found host: " ++ show host
          -- First, attempt to identify each drive
          sdevs <- forM (zip drives [0..length drives]) $ \(drive, idx) -> do
            let
              midentity = sensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentity drive
              status = sensorResponseMessageSensor_response_typeRaid_dataDrivesItemStatus drive
            (fmap (, status)) <$> case midentity of
              Just ident -> let
                  path = sensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentityPath ident
                  sn = sensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentitySerialNumber ident
                  devIds = [ DIPath (T.unpack path)
                           , DISerialNumber (T.unpack sn)
                           , DIRaidDevice device
                           , DIRaidIdx idx
                           ]
                in Just . (, path, sn) <$> do
                  mdev <- findHostStorageDevices host
                          >>= filterM (flip hasStorageDeviceIdentifier $ DISerialNumber (T.unpack sn))
                  phaseLog "debug" $ "IDs: " ++ show devIds
                  dev <- case mdev of
                    [] -> do
                      sdev <- StorageDevice <$> liftIO nextRandom
                      phaseLog "debug" $ "Creating new storage device: " ++ show sdev
                      locateStorageDeviceOnHost host sdev
                      return sdev
                    [sdev] -> return sdev
                    sdevs -> do
                      phaseLog "warning" $ "Multiple devices with same IDs: " ++ show sdevs
                      mergeStorageDevices sdevs
                  identifyStorageDevice dev devIds
                  return dev
              Nothing -> do -- We have no device identifiers here
                -- See if we can find identifiers
                runMaybeT $ do
                  dev <- MaybeT $ findHostStorageDevices host
                        >>= filterM (flip hasStorageDeviceIdentifier $ DIRaidIdx idx)
                        >>= \case
                          [] -> do
                            phaseLog "error" $ "Metadata drive at index " ++ (show idx)
                                            ++ " failed, but we have no prior information for"
                                            ++ " a drive in this position."
                            return Nothing
                          [sdev] -> return $ Just sdev
                          sdevs -> do
                            phaseLog "warning" $ "Multiple devices with same IDs: " ++ show sdevs
                            Just <$> mergeStorageDevices sdevs
                  path <- MaybeT $ (fmap T.pack . listToMaybe) <$> lookupStorageDevicePaths dev
                  serial <- MaybeT $ (fmap T.pack . listToMaybe) <$> lookupStorageDeviceSerial dev
                  return (dev, path, serial)

          isReassembling <- getLocalGraph
                            <&> isConnected host Is ReassemblingRaid
          let
            go [] = return ()
            go ((sdev, path, _sn):xs) = do
              fork CopyNewerBuffer $ do
                phaseLog "action" $ "Metadrive drive " ++ show path
                                  ++ "failed on " ++ show nid ++ "."
                msgUuid <- liftIO $ nextRandom
                put Local $ Just (nid, msgUuid, sdev, device_t, path)
                -- Tell SSPL to remove the drive from the array
                removed <- sendNodeCmd nid (Just msgUuid)
                            (NodeRaidCmd device_t (RaidRemove path))
                -- Start the reset operation for this disk
                if removed
                then do
                  promulgateRC $ ResetAttempt sdev
                  switch [reset_success, reset_failure, timeout 120 end]
                else do
                  phaseLog "error" $ "Failed to send ResetAttept command via SSPL."
                  continue end
              go xs

          if isReassembling
          then go . fmap fst . filter (\(_,x) -> x == "_") $ catMaybes sdevs
          else phaseLog "info" $ "RAID device is reassembling; not attempting "
                              ++ "further action."
      done uid

  setPhaseIf reset_success
    ( \(HAEvent eid (ResetSuccess x) _) _ l -> case l of
        Just (_,_,y,_,_) | x == y -> return $ Just eid
        _ -> return Nothing
    ) $ \eid -> do
      Just (nid, _, _, device, path) <- get Local
      -- Add drive back into array
      void $ sendNodeCmd nid Nothing (NodeRaidCmd device (RaidAdd path))
      messageProcessed eid
      -- At this point we are done
      continue end

  setPhaseIf reset_failure
    ( \(HAEvent eid (ResetFailure x) _) _ l -> case l of
        Just (_,_,y,_,_) | x == y -> return $ Just eid
        _ -> return Nothing
    ) $ \eid -> do
      messageProcessed eid
      continue end

  directly end stop

  startFork raid_msg Nothing

ruleMonitorExpanderReset :: Definitions LoopState ()
ruleMonitorExpanderReset = defineSimpleTask "monitor-expander-reset" $ \(nid, ExpanderResetInternal) -> do
  menc <- runMaybeT $ do
    host <- MaybeT $ findNodeHost (Node nid)
    MaybeT $ findHostEnclosure host
  forM_ menc $ promulgateRC . ExpanderReset

ruleThreadController :: Definitions LoopState ()
ruleThreadController = defineSimple "monitor-thread-controller" $ \(HAEvent uuid (nid, artc) _) -> let
    module_name = actuatorResponseMessageActuator_response_typeThread_controllerModule_name artc
    thread_response = actuatorResponseMessageActuator_response_typeThread_controllerThread_response artc
  in do
     case (T.toUpper module_name, T.toUpper thread_response) of
       ("THREADCONTROLLER", "SSPL-LL SERVICE HAS STARTED SUCCESSFULLY") -> do
         mhost <- findNodeHost (Node nid)
         case mhost of
           Nothing -> phaseLog "error" $ "can't find host for node " ++ show nid
           Just host -> do
             msds <- runMaybeT $ do
               encl <- MaybeT $ findHostEnclosure host
               lift $ findEnclosureStorageDevices encl >>=
                        traverse (\x -> do
                          liftA2 (x,,) <$> driveStatus x
                                       <*> fmap listToMaybe (lookupStorageDeviceSerial x))
             forM_ msds $ \sds -> forM_ (catMaybes sds) $ \(_, status, serial) ->
               case status of
                 StorageDeviceStatus "HALON-FAILED" reason -> do
                   _ <- sendNodeCmd nid Nothing (DriveLed (T.pack serial) FaultOn)
                   sendLoggingCmd host $ mkDiskLoggingCmd (T.pack "HALON-FAILED")
                                                          (T.pack serial)
                                                          (T.pack reason)
                 _ -> return ()
       _ -> return ()
     messageProcessed uuid

  -- SSPL Monitor interface data
  -- defineSimpleIf "monitor-if-update" (\(HAEvent _ (_ :: NodeId, hum) _) _ ->
  --     return $ sensorResponseMessageSensor_response_typeIf_data hum
  --   ) $ \(SensorResponseMessageSensor_response_typeIf_data hn _ ifs') ->
  --     let
  --       host = Host . T.unpack $ fromJust hn
  --       ifs = join $ maybeToList ifs' -- Maybe List, for some reason...
  --       addIf i = registerInterface host . Interface . T.unpack . fromJust
  --         $ sensorResponseMessageSensor_response_typeIf_dataInterfacesItemIfId i
  --     in do
  --       phaseLog "action" $ "Adding interfaces to host " ++ show host
  --       forM_ ifs addIf

  -- Dummy rule for handling SSPL HL commands
ruleSystemdCmd :: Service SSPLConf -> Definitions LoopState ()
ruleSystemdCmd sspl = defineSimpleIf "systemd-cmd" (\(HAEvent uuid cr _ ) _ ->
    return . fmap (uuid,) . commandRequestMessageServiceRequest
              . commandRequestMessage
              $ cr
    ) $ \(uuid,sr) -> do
      let
        serviceName = commandRequestMessageServiceRequestServiceName sr
        command = commandRequestMessageServiceRequestCommand sr
        nodeFilter = case commandRequestMessageServiceRequestNodes sr of
          Just foo -> T.unpack foo
          Nothing -> "."
      case command of
        Aeson.String "start" -> do
          nodes <- findHosts nodeFilter
                    >>= mapM nodesOnHost
                    >>= return . join
                    >>= filterM (\a -> fmap not $ isServiceRunning a sspl)
          phaseLog "action" $ "Starting " ++ (T.unpack serviceName)
                          ++ " on nodes " ++ (show nodes)
          forM_ nodes $ \(Node nid) -> do
            sendSystemdCmd nid $ SystemdCmd serviceName SERVICE_START
        Aeson.String "stop" -> do
          nodes <- findHosts nodeFilter
                    >>= mapM nodesOnHost
                    >>= return . join
                    >>= filterM (\a -> isServiceRunning a sspl)
          phaseLog "action" $ "Stopping " ++ (T.unpack serviceName)
                          ++ " on nodes " ++ (show nodes)
          forM_ nodes $ \(Node nid) -> do
            sendSystemdCmd nid $ SystemdCmd serviceName SERVICE_STOP
        Aeson.String "restart" -> do
          nodes <- findHosts nodeFilter
                    >>= mapM nodesOnHost
                    >>= return . join
                    >>= filterM (\a -> isServiceRunning a sspl)
          phaseLog "action" $ "Restarting " ++ (T.unpack serviceName)
                          ++ " on nodes " ++ (show nodes)
          forM_ nodes $ \(Node nid) -> do
            sendSystemdCmd nid $ SystemdCmd serviceName SERVICE_RESTART
        -- Aeson.String "enable" -> liftProcess $ say "Unsupported."
        -- Aeson.String "disable" -> liftProcess $ say "Unsupported."
        -- Aeson.String "status" -> liftProcess $ say "Unsupported."
        x -> liftProcess . say $ "Unsupported service command: " ++ show x
      messageProcessed uuid

ruleHlNodeCmd :: Service SSPLConf -> Definitions LoopState ()
ruleHlNodeCmd sspl = defineSimpleIf "sspl-hl-node-cmd" (\(HAEvent uuid cr _ ) _ ->
    return . fmap (uuid,) .  commandRequestMessageNodeStatusChangeRequest
              . commandRequestMessage
              $ cr
    ) $ \(uuid,sr) ->
      let
        command = commandRequestMessageNodeStatusChangeRequestCommand sr
        nodeFilter = case commandRequestMessageNodeStatusChangeRequestNodes sr of
          Just foo -> T.unpack foo
          Nothing -> "."
      in do
        actuationNode <- findActuationNode sspl
        hosts <- fmap catMaybes
                $ findHosts nodeFilter
              >>= mapM findBMCAddress
        case command of
          Aeson.String "poweroff" -> do
            phaseLog "action" $ "Powering off hosts " ++ (show hosts)
            forM_ hosts $ \(nodeIp) -> do
              sendNodeCmd actuationNode Nothing $ IPMICmd IPMI_OFF (T.pack nodeIp)
          Aeson.String "poweron" -> do
            phaseLog "action" $ "Powering on hosts " ++ (show hosts)
            forM_ hosts $ \(nodeIp) -> do
              sendNodeCmd actuationNode Nothing $ IPMICmd IPMI_ON (T.pack nodeIp)
          x -> liftProcess . say $ "Unsupported node command: " ++ show x
        messageProcessed uuid

-- | Send update to SSPL that the given 'StorageDevice' changed its status.
updateDriveManagerWithFailure :: StorageDevice
                              -> String
                              -> Maybe String
                              -> PhaseM LoopState l ()
updateDriveManagerWithFailure disk st reason = do
  updateDriveStatus disk st (fromMaybe "NONE" reason)
  dis <- findStorageDeviceIdentifiers disk
  case listToMaybe [ sn' | DISerialNumber sn' <- dis ] of
    Nothing -> phaseLog "error" $ "Unable to find serial number for " ++ show disk
    Just sn -> do
      rg <- getLocalGraph
      withHost rg disk $ \host -> do
        _ <- sendLedUpdate DrivePermanentlyFailed host (T.pack sn)
        sendLoggingCmd host $ mkDiskLoggingCmd (T.pack st)
                                               (T.pack sn)
                                               (maybe "unknown reason" T.pack reason)
  where
    withHost rg d f =
      case listToMaybe $ connectedFrom Has d rg of
        Nothing -> phaseLog "error" $ "Unable to find enclosure for " ++ show d
        Just e -> case listToMaybe $ connectedTo (e::Enclosure) Has rg of
          Nothing -> phaseLog "error" $ "Unable to find host for " ++ show e
          Just h -> f (h::Host)

ruleSSPLTimeout :: Service SSPLConf -> Definitions LoopState ()
ruleSSPLTimeout sspl = defineSimple "sspl-service-timeout" $
      \(HAEvent uuid (SSPLServiceTimeout node) _) -> do
          phaseLog "warning" "SSPL didn't send any message withing timeout - restarting."
          mservice <- lookupRunningService (Node node) sspl
          forM_ mservice $ \(ServiceProcess pid) ->
            liftProcess $ usend pid ResetSSPLService
          messageProcessed uuid

ruleSSPLConnectFailure :: Definitions LoopState ()
ruleSSPLConnectFailure = defineSimple "sspl-service-connect-failure" $
      \(HAEvent uuid (SSPLConnectFailure nid) _) -> do
          phaseLog "error" $ "SSPL service can't connect to rabbitmq on node: " ++ show nid
          messageProcessed uuid
