{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}
-- |
-- Module    : HA.Services.SSPL.CEP.
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- @halon:sspl@ service rules
module HA.Services.SSPL.CEP
  ( DriveLedUpdate(..)
  , initialRule
  , sendInterestingEvent
  , sendLedUpdate
  , sendNodeCmd
  , sendNodeCmdChan
  , ssplRules
  , updateDriveManagerWithFailure
  ) where

import           Control.Applicative
import           Control.Distributed.Process
import           Control.Lens ((<&>))
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.Maybe
import           Data.Binary (Binary)
import           Data.Foldable (for_)
import           Data.Function (fix)
import           Data.Maybe (catMaybes, listToMaybe)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Data.Traversable (for)
import           Data.Typeable (Typeable)
import           Data.UUID (UUID)
import           GHC.Generics
import qualified HA.Aeson as Aeson
import           HA.EventQueue (HAEvent(..))
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Castor.Drive.Events
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import qualified HA.RecoveryCoordinator.Service.Actions as Service
import           HA.ResourceGraph hiding (null)
import           HA.Resources (Node(..), Has(..), Cluster(..))
import           HA.Resources.Castor
import           HA.Service hiding (configDict)
import           HA.Services.SSPL.IEM
import           HA.Services.SSPL.LL.RC.Actions
import           HA.Services.SSPL.LL.Resources
import           Network.CEP
import           SSPL.Bindings

import           HA.RecoveryCoordinator.Mero.State
import           HA.RecoveryCoordinator.Mero.Transitions
import qualified HA.RecoveryCoordinator.Mero.Actions.Conf as M0
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           Mero.ConfC (strToFid)
import           Text.Read (readMaybe)

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

-- | Send 'InterestingEventMessage' to any IEM channel available.
sendInterestingEvent :: InterestingEventMessage
                     -> PhaseM RC l ()
sendInterestingEvent msg = do
  phaseLog "action" "Sending InterestingEventMessage."
  chanm <- listToMaybe <$> getAllIEMChannels
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan msg
    _ -> phaseLog "warning" "Cannot find IEM channel!"

-- | Send command to logger actuator.
--
-- Logger actuator command is used to forcefully set drives status using
-- SSPL and sent related IEM message.
sendLoggingCmd :: Host
               -> LoggerCmd
               -> PhaseM RC l ()
sendLoggingCmd host req = do
  phaseLog "action" $ "Sending Logger request" ++ show req
  -- For test purposes, publish the LoggerCmd sent
  publish req
  rg <- getLocalGraph
  mchan <- listToMaybe . catMaybes <$>
             for (connectedTo host Runs rg) getCommandChannel
  case mchan of
    Just (Channel chan) -> liftProcess $ sendChan chan (Nothing, makeLoggerMsg req)
    _ -> phaseLog "error" "Cannot find sspl channel!"

-- | Create a 'LoggerCmd'.
mkDiskLoggingCmd :: T.Text -- ^ Status
                 -> T.Text -- ^ Serial Number
                 -> T.Text -- ^ Reason
                 -> LoggerCmd
mkDiskLoggingCmd st serial reason = LoggerCmd message "LOG_WARNING" "HDS" where
  message = "{'status': '" <> st <> "', 'reason': '" <> reason <> "', 'serial_number': '" <> serial <> "'}"

-- | Drive states that should be reflected by LED.
data DriveLedUpdate = DrivePermanentlyFailed -- ^ Drive is failed permanently
                    | DriveTransientlyFailed -- ^ Drive is beign reset or smart check
                    | DriveRebalancing       -- ^ Rebalance operation is happening on a drive
                    | DriveOk                -- ^ Drive is ok
                    deriving (Show)

-- | Send information about 'DriveLedUpdate' to the given 'Host' for
-- the drive with the given serial number.
sendLedUpdate :: DriveLedUpdate -- ^ Drive state we want to signal
              -> Host -- ^ Host we want to deal with
              -> T.Text -- ^ Drive serial number
              -> PhaseM RC l Bool
sendLedUpdate status host sn = do
  phaseLog "action" $ "Sending Led update " ++ show status ++ " about " ++ show sn ++ " on " ++ show host
  rg <- getLocalGraph
  let mnode = listToMaybe $
                connectedTo host Runs rg -- XXX: try all nodes
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
            -> PhaseM RC l Bool
sendNodeCmd nid muuid req = do
  phaseLog "action" $ "Sending node actuator request: " ++ show req
  chanm <- getCommandChannel (Node nid)
  case chanm of
    Just chan -> do sendNodeCmdChan chan muuid req
                    return True
    _ -> do phaseLog "warning" "Cannot find command channel!"
            return False

-- | Like 'sendNodeCmd' but sends to the given channel.
sendNodeCmdChan :: CommandChan
                -> Maybe UUID
                -> NodeCmd
                -> PhaseM RC l ()
sendNodeCmdChan (Channel chan) muuid req =
  liftProcess $ sendChan chan (muuid, makeNodeMsg req)

--------------------------------------------------------------------------------
-- Rules                                                                      --
--------------------------------------------------------------------------------

-- | SSPL rules.
ssplRules :: Service SSPLConf -> Definitions RC ()
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
  , ruleMonitorServiceFailed
  ]

-- | Ask any running SSPL services to their channels ('RequestChannels').
initialRule :: Service SSPLConf -> PhaseM RC l () -- XXX: remove first argument
initialRule sspl = do
   rg <- getLocalGraph
   let nodes = [ n | host <- connectedTo Cluster Has rg :: [Host]
               , n <- connectedTo host Runs rg :: [Node]
               , not . null $ lookupServiceInfo n sspl rg
               ]
   liftProcess $ for_ nodes $ \(Node nid) -> -- XXX: wait for reply ?!
     nsendRemote nid (serviceLabel sspl) RequestChannels

ruleDeclareChannels :: Definitions RC ()
ruleDeclareChannels = defineSimpleTask "declare-channels" $
      \(DeclareChannels pid (ActuatorChannels iem systemd)) -> do
          let node = Node (processNodeId pid)
          storeIEMChannel node (Channel iem)
          storeCommandChannel node (Channel systemd)
          liftProcess $ usend pid ()

data RuleDriveManagerDisk = RuleDriveManagerDisk StorageDevice
  deriving (Eq,Show,Generic,Typeable)

instance Binary RuleDriveManagerDisk

-- | SSPL Monitor drivemanager.
--
-- Monitor drive manager rules consumes events that come in drive manager subsystem
-- in SSPL-LL service. Such events are emited when drive status is changed in OS
-- that may happen when OS either see that drive either:
--   * FAILED - failed because of smart or other
--   * EMPTY  - drive is removed or poweref off
--   * OK     - drive is avaliable to OS.
--
-- Upon receiving such even rule stores status to appropriate drive, basically populating
-- device path that were not available after HPI event and emits next message:
--
--   * FAILED -> 'DriveFailed'
--   * EMPTY  -> 'Transient'
--   * OK     -> 'DriveOK'
--
-- If drive is under reset, so we know that we are not interested in EMPTY/OK events
-- rule ignores such events.
ruleMonitorDriveManager :: Definitions RC ()
ruleMonitorDriveManager = defineSimple "sspl::monitor-drivemanager" $ \(HAEvent uuid (nid, srdm)) -> do
  let enc' = Enclosure . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN
                       $ srdm
      diskNum = fromInteger $ sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum srdm
      diidx = DIIndexInEnclosure diskNum
      sn = T.unpack
           . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerialNumber
           $ srdm
      path = T.unpack
             . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerPathID
             $ srdm
      disk_status = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus srdm
      disk_reason = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskReason srdm
  todo uuid
  Log.tagContext Log.SM uuid Nothing
  Log.tagContext Log.SM (StorageDevice sn) $ Just "sspl::monitor-drivemanager"
  Log.tagContext Log.SM [ ("drive.path"   :: String, show path)
                        , ("drive.idx"    :: String, show diidx)
                        , ("drive.status" :: String, T.unpack disk_reason)
                        , ("drive.reason" :: String, T.unpack disk_status)
                        ] Nothing
  enc <- populateEnclosure enc' sn diskNum
  sdev_loc <- StorageDevice.mkLocation enc diskNum
  Log.tagContext Log.SM [ ("drive.location" :: String, show sdev_loc) ] Nothing
  disk <- populateStorageDevice sn path
  M0.associateLocationWithSDev sdev_loc
  fix $ \next -> do
    eresult <- StorageDevice.insertTo disk sdev_loc
    case eresult of
      Right () -> notify $ DriveInserted uuid (Node nid) sdev_loc disk True
      Left StorageDevice.AlreadyInstalled -> return ()
      Left (StorageDevice.InAnotherSlot slot) -> do
        StorageDevice.ejectFrom disk slot
        notify $ DriveRemoved uuid (Node nid) sdev_loc disk True
        next
      Left (StorageDevice.AnotherInSlot sdev') -> do
        StorageDevice.ejectFrom sdev' sdev_loc
        notify $ DriveRemoved uuid (Node nid) sdev_loc sdev' True
        next
      Left (StorageDevice.InAnotherEnclosure _) -> do
        Log.rcLog' Log.ERROR ("Can't deal with another device as se loose information about HPI." :: String)
        return ()
  next <- shouldContinue disk
  when next $ do
    oldDriveStatus <- StorageDevice.status disk
    case (disk_status, disk_reason) of
     (s, r) | oldDriveStatus == StorageDeviceStatus (T.unpack s) (T.unpack r) -> do
       Log.rcLog' Log.DEBUG $ "status unchanged: " ++ show oldDriveStatus
     (T.toUpper -> "FAILED", _) -> do
       StorageDevice.setStatus disk (T.unpack disk_status) (T.unpack disk_reason)
       notify $ DriveFailed uuid (Node nid) sdev_loc disk
     (T.toUpper -> "EMPTY", T.toUpper -> "NONE") -> do
       -- This is probably indicative of expander reset, or some other error.
       StorageDevice.setStatus disk (T.unpack disk_status) (T.unpack disk_reason)
       notify $ DriveTransient uuid (Node nid) sdev_loc disk
     (T.toUpper -> "OK", T.toUpper -> "NONE") -> do
       -- Disk has returned to normal after some failure.
       StorageDevice.setStatus disk (T.unpack disk_status) (T.unpack disk_reason)
       notify $ DriveOK uuid (Node nid) sdev_loc disk
     (s, r) ->
       let msg = InterestingEventMessage $ logSSPLUnknownMessage
               ( "{'type': 'actuatorRequest.manager_status', "
              <> "'reason': 'Error processing drive manager response: drive status "
               <> s <> " reason " <> r <> " is not known'}"
               )
       in sendInterestingEvent msg
  done uuid
  where
    -- If SSPL doesn't know which enclosure the drive is in, try to
    -- infer it from the drive serial number and info we may have
    -- gotten previously
    populateEnclosure enc@(Enclosure "HPI_Data_Not_Available") sn diskNum =
      StorageDevice.location (StorageDevice sn) >>= \case
        Nothing -> do
          Log.rcLog' Log.WARN ("No enclosure found for drive"::String)
          return enc
        Just (Slot enc' is)
          | is == diskNum -> return enc'
          | otherwise -> do
              Log.rcLog' Log.WARN $ "Enclosure found for drive, but drive have different id " ++ show sn
              return enc'
    populateEnclosure enc _ _ = return enc
    -- Create and populate storage device object with path, if needed.
    populateStorageDevice sn path = StorageDevice.exists sn >>= \case
      Nothing -> do
        -- Drive is not known, theorecically this means something bad is happening
        -- as we had to receive HPI event first. But it seems that this may
        -- happen under certain conditions, possibly only during tests
        -- on cluster where system may be in eventually inconsistent state.
        Log.rcLog' Log.WARN ("Drive manager event for the drive without HPI data available"::String)
        let sdev = StorageDevice sn
        StorageDevice.setPath sdev path
        return sdev
      Just sdev -> do
        -- We already have this device, we want to check if it's settings didn't change.
        -- It's higly unexpected that path could change, because it's generated based
        -- on immutable hardware settings.
        mpath <- StorageDevice.path sdev
        case mpath of
          Nothing -> StorageDevice.setPath sdev path
          Just current_path | current_path /= path -> do
            Log.rcLog' Log.WARN ("Drive unexpectidly changed it's path"::String)
            StorageDevice.setPath sdev path
          _ -> return ()
        return sdev
    -- Analyze status and decise what had happened to the drive. In case if
    -- drive is beign reset now, we should not care about it's status.
    shouldContinue disk = hasOngoingReset disk >>= \case
      True -> do
        -- Disk is under reset at the moment, we should ignore event and
        -- wait for reset to finish, really, what if drive have failed?
        Log.rcLog' Log.DEBUG $ unwords
                                 ["Ignoring DriveManager updates for disk:"
                                 , show disk
                                 , "due to disk being"
                                 , "reset"
                                 ]
        return False
      False -> return True


-- | Handle information messages about drive changes from HPI system.
ruleMonitorStatusHpi :: Definitions RC ()
ruleMonitorStatusHpi = defineSimple "sspl::monitor-status-hpi" $ \(HAEvent uuid (nid, srphi)) -> do
  let wwn = DIWWN . T.unpack
                  . sensorResponseMessageSensor_response_typeDisk_status_hpiWwn
                  $ srphi
      diskNum = fromInteger
              . sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum
              $ srphi
      serial = sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber
             $ srphi
      enc   = Enclosure . T.unpack
                   . sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN
                   $ srphi
      is_powered = sensorResponseMessageSensor_response_typeDisk_status_hpiDiskPowered srphi
      is_installed = sensorResponseMessageSensor_response_typeDisk_status_hpiDiskInstalled srphi
      sdev = StorageDevice $ T.unpack serial
      sdev_loc = Slot enc diskNum
  -- Setup context
  todo uuid
  Log.tagContext Log.SM uuid Nothing
  Log.tagContext Log.SM sdev $ Just "sspl::monitor-status-hpi"
  Log.tagContext Log.SM [ ("drive.enclosure" :: String, show enc)
                        , ("drive.wwn"       :: String, show wwn)
                        , ("drive.location"  :: String, show sdev_loc)
                        ] Nothing
  have_wwn <- StorageDevice.hasIdentifier sdev wwn
  unless have_wwn $ StorageDevice.identify sdev [wwn]
  was_powered <- StorageDevice.isPowered sdev
  isOngoingReset <- hasOngoingReset sdev
  unless isOngoingReset $ fix $ \next -> do
    eresult <- StorageDevice.insertTo sdev sdev_loc
    case eresult of
      -- New drive was installed
      Right () | is_installed -> do
        notify $ DriveInserted uuid (Node nid) sdev_loc sdev is_powered
        M0.associateLocationWithSDev sdev_loc
        -- Same drive but it was removed.
      Right () -> do
          StorageDevice.ejectFrom sdev sdev_loc -- bad
          M0.associateLocationWithSDev sdev_loc
      Left StorageDevice.AlreadyInstalled | not is_installed -> do
        StorageDevice.ejectFrom sdev sdev_loc
        notify $ DriveRemoved uuid (Node nid) sdev_loc sdev is_powered
      Left StorageDevice.AlreadyInstalled | was_powered /= is_powered ->
        notify $ DrivePowerChange uuid (Node nid) sdev_loc sdev is_powered
      Left (StorageDevice.InAnotherEnclosure _) -> do -- FIXME: can we do something here?
        Log.rcLog' Log.ERROR
          ("Can't send drive removed event, because another device slot is unknown" :: String)
      Left (StorageDevice.AnotherInSlot asdev) -> do
        Log.withLocalContext' $ do
          M0.associateLocationWithSDev sdev_loc
          Log.tagLocalContext sdev Nothing
          Log.tagLocalContext [("location"::String, show sdev_loc)] Nothing
          Log.rcLog Log.ERROR
            ("Insertion in a slot where previous device was inserted - removing old device.":: String)
          asdev `StorageDevice.ejectFrom` sdev_loc
          notify $ DriveRemoved uuid (Node nid) sdev_loc sdev is_powered
        next
      Left (StorageDevice.InAnotherSlot slot) -> do
        M0.associateLocationWithSDev slot
        Log.rcLog' Log.ERROR
          ("Storage device was associated with another slot.":: String)
        StorageDevice.ejectFrom sdev slot
        notify $ DriveRemoved uuid (Node nid) sdev_loc sdev is_powered
        next
      _ -> return ()
  done uuid

-- | Handle SSPL message about a service failure.
ruleMonitorServiceFailed :: Definitions RC ()
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
              modifyLocalGraph $ return . connect p Has (M0.PID currentPid)
            applyStateChanges [stateSet p $ processFailed "SSPL notification about service failure"]
      case listToMaybe $ filter (\p -> M0.r_fid p == processFid) svs of
        Nothing -> phaseLog "warn" $ "Couldn't find process with fid " ++ show processFid
        Just p -> do
          rg <- getLocalGraph
          case (getState p rg, connectedTo p Has rg) of
            (M0.PSFailed _, _) ->
              phaseLog "info" "Failed SSPL notification for already failed process - doing nothing."
            (M0.PSOffline, _) ->
              phaseLog "info" "Failed SSPL notification for stopped process - doing nothing."
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
              phaseLog "warning" "Pid of the process is not known - ignoring."
    _ -> return ()

-- | Monitor RAID data. We should register the RAID devices in the system,
--   with no corresponding Mero devices.
--   Raid messages from mdstat have a slightly unusual structure - we receive
--   the letter 'U' if the drive is part of the array and working, and
--   an underscore (_) if not.
ruleMonitorRaidData :: Definitions RC ()
ruleMonitorRaidData = define "monitor-raid-data" $ do

  raid_msg <- phaseHandle "raid_msg"
  reset_success <- phaseHandle "reset_success"
  reset_failure <- phaseHandle "reset_failure"
  end <- phaseHandle "end"

  setPhase raid_msg $ \(HAEvent uid (nid::NodeId, srrd)) -> let
      device_t = sensorResponseMessageSensor_response_typeRaid_dataDevice srrd
      device = T.unpack device_t
      -- Drives should have min length 2, so it's OK to access these directly
      drives = sensorResponseMessageSensor_response_typeRaid_dataDrives srrd
    in do
      todo uid
      mhost <- findNodeHost (Node nid)
      menc  <- maybe (return Nothing) findHostEnclosure mhost
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
                  sdev = StorageDevice $ T.unpack sn
                  devIds = [ DIPath (T.unpack path)
                           , DIRaidDevice device
                           , DIRaidIdx idx
                           ]
                in do Log.rcLog' Log.DEBUG $ "IDs: " ++ show devIds
                      StorageDevice.identify sdev devIds
                      -- XXX: (qnikst) we may have no HPI information about slot available. So we need to
                      -- add helper relation
                      for_ menc $ \enc -> modifyGraph $ connect enc Has sdev
                      return $ Just (sdev, path)
              Nothing -> do
                -- We have no device identifiers here
                -- See if we can find identifiers
                runMaybeT $ do
                  dev <- MaybeT $ findHostStorageDevices host
                        >>= filterM (flip StorageDevice.hasIdentifier $ DIRaidIdx idx)
                        >>= \case
                          [] -> do
                            phaseLog "error" $ "Metadata drive at index " ++ (show idx)
                                            ++ " failed, but we have no prior information for"
                                            ++ " a drive in this position."
                            return Nothing
                          [sdev] -> return $ Just sdev
                          sdevs -> do
                            phaseLog "warning" $ "Multiple devices with same IDs: " ++ show sdevs
                            Just <$> error "FIXME" -- mergeStorageDevices sdevs
                  path <- MaybeT $ fmap T.pack <$> StorageDevice.path dev
                  return (dev, path)

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
    ( \msg _ l -> case (msg, l) of
        (ResetSuccess x, Just (_,_,y,_,_)) | x == y -> return $ Just ()
        _ -> return Nothing
    ) $ \() -> do
      Just (nid, _, _, device, path) <- get Local
      -- Add drive back into array
      void $ sendNodeCmd nid Nothing (NodeRaidCmd device (RaidAdd path))
      -- At this point we are done
      continue end

  setPhaseIf reset_failure
    ( \msg _ l -> case (msg, l) of
        (ResetFailure x, Just (_,_,y,_,_)) | x == y -> return $ Just ()
        _ -> return Nothing
    ) $ \() -> do
      -- TODO: log an IEM (SEM?) here that things are wrong
      continue end

  directly end stop

  startFork raid_msg Nothing

ruleMonitorExpanderReset :: Definitions RC ()
ruleMonitorExpanderReset = defineSimpleTask "monitor-expander-reset" $ \(nid, ExpanderResetInternal) -> do
  menc <- runMaybeT $ do
    host <- MaybeT $ findNodeHost (Node nid)
    MaybeT $ findHostEnclosure host
  forM_ menc $ promulgateRC . ExpanderReset

ruleThreadController :: Definitions RC ()
ruleThreadController = defineSimpleTask "monitor-thread-controller" $ \(nid, artc) -> let
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
                          liftA (x,) <$> fmap Just (StorageDevice.status x))
             encl' <- findHostEnclosure host
             phaseLog "debug" $ "MSDS: " ++ show (catMaybes <$> msds, host, encl')
             forM_ msds $ \sds -> forM_ (catMaybes sds) $ \(StorageDevice serial, status) ->
               case status of
                 StorageDeviceStatus "HALON-FAILED" reason -> do
                   _ <- sendNodeCmd nid Nothing (DriveLed (T.pack serial) FaultOn)
                   sendLoggingCmd host $ mkDiskLoggingCmd (T.pack "HALON-FAILED")
                                                          (T.pack serial)
                                                          (T.pack reason)
                 _ -> return ()
       _ -> return ()

  -- SSPL Monitor interface data
  -- defineSimpleIf "monitor-if-update" (\(HAEvent _ (_ :: NodeId, hum)) _ ->
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

ruleHlNodeCmd :: Service SSPLConf -> Definitions RC ()
ruleHlNodeCmd _sspl = defineSimpleIf "sspl-hl-node-cmd" (\(HAEvent uuid cr) _ ->
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
                              -> PhaseM RC l ()
updateDriveManagerWithFailure disk@(StorageDevice sn) st reason = do
   rg <- getLocalGraph
   withHost rg disk $ \host -> do
     _ <- sendLedUpdate DrivePermanentlyFailed host (T.pack sn)
     sendLoggingCmd host $ mkDiskLoggingCmd (T.pack st)
                                            (T.pack sn)
                                            (maybe "unknown reason" T.pack reason)
  where
    withHost rg d f =
      case connectedFrom Has d rg of
        Nothing -> phaseLog "error" $ "Unable to find enclosure for " ++ show d
        Just e -> case connectedTo (e::Enclosure) Has rg of
          []    -> phaseLog "error" $ "Unable to find host for " ++ show e
          h : _ -> f (h::Host)

ruleSSPLTimeout :: Service SSPLConf -> Definitions RC ()
ruleSSPLTimeout sspl = defineSimple "sspl-service-timeout" $
      \(HAEvent uuid (SSPLServiceTimeout nid)) -> do
          mcfg <- Service.lookupInfoMsg (Node nid) sspl
          for_ mcfg $ \_ -> do
            phaseLog "warning" "SSPL didn't send any message withing timeout - restarting."
            liftProcess $ nsendRemote nid (serviceLabel sspl) ResetSSPLService
          messageProcessed uuid

ruleSSPLConnectFailure :: Definitions RC ()
ruleSSPLConnectFailure = defineSimple "sspl-service-connect-failure" $
      \(HAEvent uuid (SSPLConnectFailure nid)) -> do
          phaseLog "error" $ "SSPL service can't connect to rabbitmq on node: " ++ show nid
          messageProcessed uuid
