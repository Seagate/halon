-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE ViewPatterns        #-}
module HA.Services.SSPL.CEP where

import HA.Services.SSPL.LL.RC.Actions

import HA.EventQueue.Types (HAEvent(..))
import HA.Service hiding (configDict)
import HA.Services.SSPL.IEM
import HA.Services.SSPL.LL.Resources
import HA.RecoveryCoordinator.Mero

import HA.RecoveryCoordinator.Castor.Drive.Events
import qualified HA.RecoveryCoordinator.Actions.Service as Service
import HA.ResourceGraph hiding (null)
import HA.Resources (Node(..), Has(..), Cluster(..))
import HA.Resources.Castor
#ifdef USE_MERO
import HA.RecoveryCoordinator.Rules.Mero.Conf -- XXX: remove if possible
import HA.Resources.Mero.Note
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (showFid)
import Mero.ConfC (strToFid)
import Mero.Notification
import Text.Read (readMaybe)
#endif

import SSPL.Bindings

import Control.Applicative
import Control.Distributed.Process
  ( NodeId
  , sendChan
  , say
  , processNodeId
  , nsendRemote
  )
import Control.Lens ((<&>))
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Maybe

import qualified Data.Aeson as Aeson
import Data.Maybe (catMaybes, listToMaybe, fromMaybe)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import Data.UUID (UUID)
import Data.Binary (Binary)
import Data.Foldable (for_)
import Data.Traversable (for)
import Data.Typeable (Typeable)

import Network.CEP
import GHC.Generics

import Prelude hiding (mapM_)

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

sendInterestingEvent :: InterestingEventMessage
                     -> PhaseM LoopState l ()
sendInterestingEvent msg = do
  phaseLog "action" "Sending InterestingEventMessage."
  chanm <- listToMaybe <$> getAllIEMChannels
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan msg
    _ -> phaseLog "warning" "Cannot find IEM channel!"

-- | Send command for system on remove node.
sendSystemdCmd :: NodeId
               -> SystemdCmd
               -> PhaseM LoopState l ()
sendSystemdCmd nid req = do
  phaseLog "action" $ "Sending Systemd request" ++ show req
  chanm <- getCommandChannel (Node nid)
  case chanm of
    Just chan -> sendSystemdCmdChan chan req
    _ -> phaseLog "warning" "Cannot find systemd channel!"

sendSystemdCmdChan :: Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)
                   -> SystemdCmd
                   -> PhaseM LoopState l ()
sendSystemdCmdChan (Channel chan) req =
  liftProcess $ sendChan chan (Nothing, makeSystemdMsg req)

-- | Send command to logger actuator.
--
-- Logger actuator command is used to forcefully set drives status using
-- SSPL and sent related IEM message.
sendLoggingCmd :: Host
               -> LoggerCmd
               -> PhaseM LoopState l ()
sendLoggingCmd host req = do
  phaseLog "action" $ "Sending Logger request" ++ show req
  rg <- getLocalGraph
  mchan <- listToMaybe . catMaybes <$> for (connectedTo host Runs rg) getCommandChannel
  case mchan of
    Just (Channel chan) -> liftProcess $ sendChan chan (Nothing, makeLoggerMsg req)
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
  let mnode = listToMaybe $ connectedTo host Runs rg -- XXX: try all nodes
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
  chanm <- getCommandChannel (Node nid)
  case chanm of
    Just chan -> do sendNodeCmdChan chan muuid req
                    return True
    _ -> do phaseLog "warning" "Cannot find command channel!"
            return False

sendNodeCmdChan :: Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)
                -> Maybe UUID
                -> NodeCmd
                -> PhaseM LoopState l ()
sendNodeCmdChan (Channel chan) muuid req =
  liftProcess $ sendChan chan (muuid, makeNodeMsg req)


--------------------------------------------------------------------------------
-- Rules                                                                      --
--------------------------------------------------------------------------------

ssplRules :: Service SSPLConf -> Definitions LoopState ()
ssplRules sspl = sequence_
  [ ruleDeclareChannels
  , ruleMonitorDriveManager
  , ruleMonitorStatusHpi
  , ruleMonitorRaidData
  , ruleHlNodeCmd sspl
  , ruleThreadController
  , ruleSSPLTimeout sspl
  , ruleSSPLConnectFailure
  , ruleMonitorExpanderReset
#ifdef USE_MERO
  , ruleMonitorServiceFailed
#endif
  ]

initialRule :: Service SSPLConf -> PhaseM LoopState l () -- XXX: remove first argument
initialRule sspl = do
   rg <- getLocalGraph
   let nodes = [ n | host <- connectedTo Cluster Has rg :: [Host]
               , n <- connectedTo host Runs rg :: [Node]
               , not . null $ lookupServiceInfo n sspl rg
               ]
   liftProcess $ for_ nodes $ \(Node nid) -> -- XXX: wait for reply ?!
     nsendRemote nid (serviceLabel sspl) RequestChannels

ruleDeclareChannels :: Definitions LoopState ()
ruleDeclareChannels = defineSimpleTask "declare-channels" $
      \(DeclareChannels pid (ActuatorChannels iem systemd)) -> do
          let node = Node (processNodeId pid)
          storeIEMChannel node (Channel iem)
          storeCommandChannel node (Channel systemd)
          ack pid

data RuleDriveManagerDisk = RuleDriveManagerDisk StorageDevice
  deriving (Eq,Show,Generic,Typeable)

instance Binary RuleDriveManagerDisk

-- | SSPL Monitor drivemanager
--
-- TODO: remove RuleDriveManagerDisk and use 'continue' instead
-- TODO: todo/done for good measure
ruleMonitorDriveManager :: Definitions LoopState ()
ruleMonitorDriveManager = define "sspl::monitor-drivemanager" $ do
   pinit  <- phaseHandle "init"
   pcommit <- phaseHandle "after commit to graph"
   finish <- phaseHandle "finish"

   setPhase pinit $ \(HAEvent uuid (nid, srdm) _) -> fork CopyNewerBuffer $ do
     let enc' = Enclosure . T.unpack
                          . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN
                          $ srdm
         diskNum = fromInteger $ sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum srdm
         diidx = DIIndexInEnclosure diskNum
         sn = DISerialNumber . T.unpack
                . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerialNumber
                $ srdm
         path = DIPath . T.unpack
                . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerPathID
                $ srdm

     phaseLog "sspl-service" $ "monitor-drivemanager request received."
     phaseLog "enclosure"    $ show enc'
     phaseLog "drive.sn"     $ show sn
     phaseLog "drive.path"   $ show path
     phaseLog "drive.idx"    $ show diidx

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
             -- TODO: don't return enc' but just abort
             return enc'
           Just enc'' -> return enc''
       _ -> return enc'

     put Local $ Just (uuid, nid, enc, diskNum, srdm, sn, path)
     lookupStorageDeviceInEnclosure enc diidx >>= \case
       Nothing ->
         -- Try to check if we have device with known serial number, just without location.
         lookupStorageDeviceInEnclosure enc sn >>= \case
           Just disk -> do
             phaseLog "sspl-service" $ "Drive not found by index. Found device "
                                    ++ show disk ++ " by serial number."
             phaseLog "disk" $ show disk
             -- TODO: we don't want to blindly set path, should verify if it matches and panic if not
             identifyStorageDevice disk [diidx, path]
             selfMessage $ RuleDriveManagerDisk disk
           Nothing -> do
             phaseLog "sspl-service"
                 $ "Cant find disk in " ++ show enc ++ " at " ++ show diskNum ++ " creating new entry."
             diskUUID <- liftIO $ nextRandom
             let disk = StorageDevice diskUUID
             locateStorageDeviceInEnclosure enc disk
             mhost <- findNodeHost (Node nid)
             forM_ mhost $ \host -> do
               locateStorageDeviceOnHost host disk
               locateHostInEnclosure host enc
             identifyStorageDevice disk [diidx, sn, path]
             selfMessage $ RuleDriveManagerDisk disk
       Just st -> selfMessage (RuleDriveManagerDisk st)
     continue pcommit

   setPhase pcommit $ \(RuleDriveManagerDisk disk) -> do
     Just (uuid, nid, enc, _diskNum, srdm, _sn, _path) <- get Local
     phaseLog "disk" $ show disk
     let
      disk_status = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus srdm
      disk_reason = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskReason srdm

     oldDriveStatus <- maybe (StorageDeviceStatus "" "") id <$> driveStatus disk
     isOngoingReset <- hasOngoingReset disk

     if isOngoingReset
     then do
       phaseLog "info" $ unwords [
                            "Ignoring DriveManager updates for disk:"
                          , show disk
                          , "due to disk being"
                          , "reset"
                          ]
       messageProcessed uuid
     else
       case (disk_status, disk_reason) of
        (s, r) | oldDriveStatus == StorageDeviceStatus (T.unpack s) (T.unpack r) -> do
          phaseLog "sspl-service" $ "status unchanged: " ++ show oldDriveStatus
          messageProcessed uuid
        (T.toUpper -> "FAILED", _) -> do
          updateDriveStatus disk (T.unpack disk_status) (T.unpack disk_reason)
          notify $ DriveFailed uuid (Node nid) enc disk
        (T.toUpper -> "EMPTY", T.toUpper -> "NONE") -> do
          -- This is probably indicative of expander reset, or some other error.
          updateDriveStatus disk (T.unpack disk_status) (T.unpack disk_reason)
          notify $ DriveTransient uuid (Node nid) enc disk
        (T.toUpper -> "OK", T.toUpper -> "NONE") -> do
          -- Disk has returned to normal after some failure.
          updateDriveStatus disk (T.unpack disk_status) (T.unpack disk_reason)
          notify $ DriveOK uuid (Node nid) enc disk
        (s,r) -> let
            msg = InterestingEventMessage $ logSSPLUnknownMessage
                  ( "{'type': 'actuatorRequest.manager_status', "
                  <> "'reason': 'Error processing drive manager response: drive status "
                  <> s <> " reason " <> r <> " is not known'}"
                  )
          in do
            sendInterestingEvent msg
            messageProcessed uuid
     continue finish

   directly finish stop

   start pinit Nothing

-- | Handle information messages about drive changes from HPI system.
ruleMonitorStatusHpi :: Definitions LoopState ()
ruleMonitorStatusHpi = defineSimple "sspl::monitor-status-hpi" $ \(HAEvent uuid (nid, srphi) _) -> do
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
      phaseLog "enclosure" $ show enc
      phaseLog "drive.wwn" $ show wwn
      phaseLog "drive.idx" $ show idx
      phaseLog "drive.sn"  $ show serial

      existingByIdx <- lookupStorageDeviceInEnclosure enc idx
      existingBySerial <- lookupStorageDeviceInEnclosure enc serial

      phaseLog "debug" $ unwords [
          "existing device by index in enclosure:", show existingByIdx
        , "existing device by serial number:", show existingBySerial
        ]

      sdev <- case (existingByIdx, existingBySerial) of
        (Just i, Just s) | i == s ->
          -- One existing device.
          return i
        (Just i, Just _) -> do
          -- Drive with this serial is known, but is not the drive in this slot.
          -- In this case the drive has probably been moved.
          -- TODO: investigate replacement with engineer temporarily pulling out drive scenario
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
          mhost <- findNodeHost (Node nid)
          forM_ mhost $ \host -> do
            locateStorageDeviceOnHost host disk
            locateHostInEnclosure host enc
          identifyStorageDevice disk [serial, wwn, idx]
          return disk

      phaseLog "sspl-service" "Found matching device"
      phaseLog "sdev" $ show sdev

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
         notify $ DriveInserted uuid (Node nid) sdev enc diskNum serial is_powered
         return True
       (False, _) | not was_removed -> do
         notify $ DriveRemoved uuid (Node nid) enc sdev diskNum is_powered
         return True
       (_, True) | not isOngoingReset && not was_powered -> do
         notify $ DrivePowerChange uuid (Node nid) enc sdev diskNum serial_str True
         return True
       (_, False) | was_powered && not isOngoingReset -> do
         notify $ DrivePowerChange uuid (Node nid) enc sdev diskNum serial_str False
         return True
       _ -> return False

      if more_needed
      then phaseLog "sspl-service" "waiting for drive manager request for the drive"
      else registerSyncGraphProcessMsg uuid

#ifdef USE_MERO
-- | Handle SSPL message about a service failure.
ruleMonitorServiceFailed :: Definitions LoopState ()
ruleMonitorServiceFailed = defineSimpleTask "monitor-service-failure" $ \(_ :: NodeId, watchdogmsg) -> do

  let currentState = sensorResponseMessageSensor_response_typeService_watchdogService_state watchdogmsg
      serviceName = sensorResponseMessageSensor_response_typeService_watchdogService_name watchdogmsg
      -- assume we have ‘service@fid.service’ format
      mprocessFid = strToFid . T.unpack . T.takeWhile (/= '.') . T.drop 1
                    $ T.dropWhile (/= '@') serviceName
      mcurrentPid = readMaybe . T.unpack
                    $ sensorResponseMessageSensor_response_typeService_watchdogPid watchdogmsg
  case (,,) <$> mprocessFid <*> mcurrentPid <*> pure currentState of
    Just (processFid, currentPid, "failed")-> do
      phaseLog "info" $ "Received SSPL message about service failure: "
                     ++ show watchdogmsg
      svs <- M0.getM0Processes <$> getLocalGraph
      phaseLog "info" $ "Looking for fid " ++ show processFid ++ " in " ++ show svs
      let markFailed p updatePid = do
            phaseLog "info" $ "Failing " ++ showFid p
            when updatePid $ do
              modifyLocalGraph $ return . connectUniqueFrom p Has (M0.PID currentPid)
            applyStateChanges [stateSet p $ M0.PSFailed "SSPL notification about service failure"]
      case listToMaybe $ filter (\p -> M0.r_fid p == processFid) svs of
        Nothing -> phaseLog "warn" $ "Couldn't find process with fid " ++ show processFid
        Just p -> do
          rg <- getLocalGraph
          case (getState p rg, listToMaybe $ connectedTo p Has rg) of
            (M0.PSFailed _, _) ->
              phaseLog "info" "Failed SSPL notification for already failed process - doing nothing."
            (M0.PSStopping, _) ->
              phaseLog "info" "Failed SSPL notification for process that is stopping - doing nothing."
            (_, Just (M0.PID pid))
              | pid == currentPid ->
                  markFailed p False
              | otherwise ->
                  -- Warn because it's probably not great to have SSPL
                  -- messages this late/out of order.
                  phaseLog "warn" $ "Current process has PID " ++ show pid
                                 ++ " but we got a failure notification for "
                                 ++ show currentPid
            (_, Nothing) -> do
              phaseLog "info" "Failed notification for currently unknown PID"
              markFailed p True
    _ -> return ()
#endif

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
            fmap (, status) <$> case midentity of
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

          if (not isReassembling)
          then promulgateRC $ RaidUpdate {
              ruNode = (Node nid)
            , ruRaidDevice = device_t
            , ruFailedComponents = fmap fst . filter (\(_,x) -> x == "_")
                                    $ catMaybes sdevs
            }
          else phaseLog "info" $ "RAID device is reassembling; not attempting "
                              ++ "further action."
      done uid

  setPhaseIf reset_success
    -- TODO: relies on drive reset rule; TODO: nicer local state
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
      -- TODO: log an IEM (SEM?) here that things are wrong
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

ruleHlNodeCmd :: Service SSPLConf -> Definitions LoopState ()
ruleHlNodeCmd _sspl = defineSimpleIf "sspl-hl-node-cmd" (\(HAEvent uuid cr _ ) _ ->
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
        mactuationChannel <- listToMaybe <$> getAllCommandChannels -- XXX: filter nodes that is not running (?)
        for_ mactuationChannel $ \actuationChannel -> do
          hosts <- fmap catMaybes
                  $ findHosts nodeFilter
                >>= mapM findBMCAddress
          case command of
            Aeson.String "poweroff" -> do
              phaseLog "action" $ "Powering off hosts " ++ (show hosts)
              forM_ hosts $ \(nodeIp) -> do
                sendNodeCmdChan actuationChannel Nothing $ IPMICmd IPMI_OFF (T.pack nodeIp)
            Aeson.String "poweron" -> do
              phaseLog "action" $ "Powering on hosts " ++ (show hosts)
              forM_ hosts $ \(nodeIp) -> do
                sendNodeCmdChan actuationChannel Nothing $ IPMICmd IPMI_ON (T.pack nodeIp)
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
      \(HAEvent uuid (SSPLServiceTimeout nid) _) -> do
          mcfg <- Service.lookupInfoMsg (Node nid) sspl
          for_ mcfg $ \_ -> do
            phaseLog "warning" "SSPL didn't send any message withing timeout - restarting."
            liftProcess $ nsendRemote nid (serviceLabel sspl) ResetSSPLService
          messageProcessed uuid

ruleSSPLConnectFailure :: Definitions LoopState ()
ruleSSPLConnectFailure = defineSimple "sspl-service-connect-failure" $
      \(HAEvent uuid (SSPLConnectFailure nid) _) -> do
          phaseLog "error" $ "SSPL service can't connect to rabbitmq on node: " ++ show nid
          messageProcessed uuid
