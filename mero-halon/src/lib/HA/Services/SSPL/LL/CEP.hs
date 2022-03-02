{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}
-- |
-- Module    : HA.Services.SSPL.LL.CEP.
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- @halon:sspl@ service rules
module HA.Services.SSPL.LL.CEP
  ( DriveLedUpdate(..)
  , sendLedUpdate
  , sendNodeCmd
  , ssplRules
  , updateDriveManagerWithFailure
  , sendInterestingEvent
  ) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.Maybe
import           Data.Binary (Binary)
import           Data.Foldable (for_)
import           Data.Maybe (catMaybes, listToMaybe)
import           Data.Monoid ((<>))
import           Data.Proxy
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import           Data.UUID (UUID)
import           GHC.Generics
import           Text.Printf (printf)
import           Text.Read (readMaybe)

import           HA.EventQueue (HAEvent(..))
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Castor.Drive.Actions
 ( updateStorageDevicePresence
 , updateStorageDeviceStatus
 )
import           HA.RecoveryCoordinator.Castor.Drive.Events
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.State
import           HA.RecoveryCoordinator.Mero.Transitions
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.RecoveryCoordinator.Service.Actions as Service
import qualified HA.ResourceGraph as G
import           HA.Resources (Node(..), Has(..), Cluster(..))
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Service hiding (configDict)
import           HA.Service.Interface
import           HA.Services.SSPL (sspl)
import           HA.Services.SSPL.IEM
import           HA.Services.SSPL.LL.Resources
import           Mero.ConfC (strToFid)
import           Network.CEP
import           SSPL.Bindings

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

-- | Find the SSPL service on any of the given nodes and send the
-- given message to it.
--
-- True if some service was found, False otherwise.
sendToSSPLSvc :: [Node] -> SsplLlToSvc -> PhaseM RC l Bool
sendToSSPLSvc nodes msg = do
  rg <- getGraph
  case findRunningServiceOn nodes sspl rg of
    Node nid : _ -> do
      Log.rcLog' Log.DEBUG
        (printf "Sending %s through SSPL on %s" (show msg) (show nid) :: String)
      sendSvc (getInterface sspl) nid msg
      return True
    [] -> do
      Log.rcLog' Log.WARN
        (printf "Can't find running SSPL service on any of %s!" (show nodes) :: String)
      return False

-- | Send 'InterestingEventMessage' to any IEM channel available.
sendInterestingEvent :: InterestingEventMessage
                     -> PhaseM RC l ()
sendInterestingEvent msg = do
  rg <- getGraph
  let nodes = [ n | n <- G.connectedTo Cluster Has rg
                  , Just m0n <- [M0.nodeToM0Node n rg]
                  , getState m0n rg == M0.NSOnline ]
  void . sendToSSPLSvc nodes $! SsplIem msg

-- | Send command to logger actuator.
--
-- Logger actuator command is used to forcefully set drives status using
-- SSPL and sent related IEM message.
sendLoggingCmd :: Node
               -> LoggerCmd
               -> PhaseM RC l ()
sendLoggingCmd node req = do
  r <- sendToSSPLSvc [node] $ SystemdMessage Nothing (makeLoggerMsg req)
  when r $ publish req

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
              -> StorageDevice -- ^ Drive
              -> PhaseM RC l Bool
sendLedUpdate status host sd@(StorageDevice (T.pack -> sn)) = do
  Log.actLog "sending LED update" [ ("status", show status)
                                  , ("sn", show sn)
                                  , ("host", show host) ]
  rg <- getGraph
  let mnode = listToMaybe $ G.connectedTo host Runs rg -- XXX: try all nodes
      modifyLedState mledSt = case G.connectedTo sd Has rg of
        Just slot@Slot{} -> modifyGraph $ case mledSt of
          Just ledSt -> G.connect slot Has ledSt
          Nothing -> G.disconnectAllFrom slot Has (Proxy :: Proxy LedControlState)
        _ -> Log.rcLog' Log.WARN $ "No slot found for " ++ show sd
  case mnode of
    Just (Node nid) -> case status of
      DrivePermanentlyFailed -> do
        modifyLedState $ Just FaultOn
        sendNodeCmd [Node nid] Nothing (DriveLed sn FaultOn)
      DriveTransientlyFailed -> do
        modifyLedState $ Just PulseFastOn
        sendNodeCmd [Node nid] Nothing (DriveLed sn PulseFastOn)
      DriveRebalancing -> do
        modifyLedState $ Just PulseSlowOn
        sendNodeCmd [Node nid] Nothing (DriveLed sn PulseSlowOn)
      DriveOk -> do
        modifyLedState Nothing
        sendNodeCmd [Node nid] Nothing (DriveLed sn FaultOff)
    _ -> do Log.rcLog' Log.ERROR ("Cannot find sspl service on the node!" :: String)
            return False

-- | Send command to nodecontroller. Reply will be received as a
-- @'HAEvent' 'SsplLlFromSvc' ('CAck')@ where UUID will be set to UUID
-- value if passed, and any random value otherwise.
sendNodeCmd :: [Node]
            -> Maybe UUID
            -> NodeCmd
            -> PhaseM RC l Bool
sendNodeCmd nodes muuid = do
  sendToSSPLSvc nodes . SystemdMessage muuid . makeNodeMsg

--------------------------------------------------------------------------------
-- Rules                                                                      --
--------------------------------------------------------------------------------

-- | SSPL rules.
ssplRules :: Definitions RC ()
ssplRules = sequence_
  [ ruleMonitorDriveManager
  , ruleMonitorStatusHpi
  , ruleMonitorRaidData
  , ruleThreadController
  , ruleSSPLTimeout
  , ruleSSPLConnectFailure
  , ruleMonitorExpanderReset
  , ruleMonitorServiceFailed
  ]

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
ruleMonitorDriveManager = defineSimpleIf "sspl::monitor-drivemanager" extract $ \(uuid, nid, srdm) -> do
  let enc' = Enclosure . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN
                       $ srdm
      diskNum = fromInteger $ sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum srdm
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
                        , ("drive.diskNum" :: String, show diskNum)
                        , ("drive.status" :: String, T.unpack disk_reason)
                        , ("drive.reason" :: String, T.unpack disk_status)
                        ] Nothing
  enc <- populateEnclosure enc' sn diskNum
  sdev_loc <- StorageDevice.mkLocation enc diskNum
  Log.tagContext Log.SM [ ("drive.location" :: String, show sdev_loc) ] Nothing
  disk <- populateStorageDevice sn path
  unless (T.unpack (T.toUpper disk_reason) =="EMPTY") $ do
    updateStorageDevicePresence uuid (Node nid) disk sdev_loc True Nothing
  next <- shouldContinue disk
  when next $ do
    result <- updateStorageDeviceStatus uuid (Node nid) disk sdev_loc
                (T.unpack disk_status)
                (T.unpack disk_reason)
    unless result $
       let msg = InterestingEventMessage $ logSSPLUnknownMessage
               ( "{'type': 'actuatorRequest.manager_status', "
               <> "'reason': 'Error processing drive manager response: drive status "
               <> disk_status <> " reason " <> disk_reason <> " is not known'}"
               )
       in sendInterestingEvent msg
  done uuid
  where
    extract (HAEvent uid (DiskStatusDm nid v)) _ = return $! Just (uid, nid, v)
    extract _ _ = return Nothing

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
ruleMonitorStatusHpi = defineSimpleIf "sspl::monitor-status-hpi" extract $ \(uuid, nid, srphi) -> do
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
  isOngoingReset <- hasOngoingReset sdev
  unless isOngoingReset $
    updateStorageDevicePresence uuid (Node nid) sdev sdev_loc
      is_installed (Just is_powered)
  done uuid
  where
    extract (HAEvent uid (DiskHpi nid v)) _ = return $! Just (uid, nid, v)
    extract _ _ = return Nothing

-- | Handle SSPL message about a service failure.
ruleMonitorServiceFailed :: Definitions RC ()
ruleMonitorServiceFailed = defineSimpleIf "monitor-service-failure" extract $ \(uid, watchdogmsg) -> do
  let currentState = sensorResponseMessageSensor_response_typeService_watchdogService_state watchdogmsg
      serviceName = sensorResponseMessageSensor_response_typeService_watchdogService_name watchdogmsg
      -- assume we have ‘service@fid.service’ format
      mprocessFid = strToFid . T.unpack . T.takeWhile (/= '.') . T.drop 1
                    $ T.dropWhile (/= '@') serviceName
      mcurrentPid = readMaybe . T.unpack
                    $ sensorResponseMessageSensor_response_typeService_watchdogPid watchdogmsg
  todo uid
  case (,,) <$> mprocessFid <*> mcurrentPid <*> pure currentState of
    Just (processFid, currentPid, "failed")-> do
      Log.rcLog' Log.DEBUG $ "Received SSPL message about service failure: "
                     ++ show watchdogmsg
      svs <- M0.getM0Processes <$> getGraph
      Log.rcLog' Log.DEBUG $ "Looking for fid " ++ show processFid ++ " in " ++ show svs
      let markFailed p updatePid = do
            Log.rcLog' Log.DEBUG $ "Failing " ++ showFid p
            when updatePid $ do
              modifyGraphM $ return . G.connect p Has (M0.PID currentPid)
            void $ applyStateChanges [stateSet p $ processFailed "SSPL notification about service failure"]
      case listToMaybe $ filter (\p -> M0.r_fid p == processFid) svs of
        Nothing -> Log.rcLog' Log.WARN $ "Couldn't find process with fid " ++ show processFid
        Just p -> do
          rg <- getGraph
          case (getState p rg, G.connectedTo p Has rg) of
            (M0.PSFailed _, _) ->
              Log.rcLog' Log.DEBUG
                ("Failed SSPL notification for already failed process - doing nothing." :: String)
            (M0.PSOffline, _) ->
              Log.rcLog' Log.DEBUG
                ("Failed SSPL notification for stopped process - doing nothing." :: String)
            (M0.PSStopping, _) ->
              Log.rcLog' Log.DEBUG
                ("Failed SSPL notification for process that is stopping - doing nothing." :: String)
            (_, Just (M0.PID pid))
              | pid == currentPid ->
                  markFailed p False
              | otherwise ->
                  -- Warn because it's probably not great to have SSPL
                  -- messages this late/out of order.
                  Log.rcLog' Log.WARN $ "Current process has PID " ++ show pid
                                     ++ " but we got a failure notification for "
                                     ++ show currentPid
            (_, Nothing) -> do
              Log.rcLog' Log.WARN ("Pid of the process is not known - ignoring." :: String)
    _ -> return ()
  done uid
  where
    extract (HAEvent uid (ServiceWatchdog v)) _ = return $! Just (uid, v)
    extract _ _ = return Nothing

-- | Monitor RAID data. We should register the RAID devices in the system,
--   with no corresponding Mero devices.
--   Raid messages from mdstat have a slightly unusual structure - we receive
--   the letter 'U' if the drive is part of the array and working, and
--   an underscore (_) if not.
ruleMonitorRaidData :: Definitions RC ()
ruleMonitorRaidData = defineSimpleIf "monitor-raid-data" extract $
  \(uid, nid, srrd) -> let
      device_t = sensorResponseMessageSensor_response_typeRaid_dataDevice srrd
      device = T.unpack device_t
      -- Drives should have min length 2, so it's OK to access these directly
      drives = sensorResponseMessageSensor_response_typeRaid_dataDrives srrd
    in do
      todo uid
      mhost <- findNodeHost (Node nid)
      case mhost of
        Nothing -> Log.rcLog' Log.ERROR $ "Cannot find host for node " ++ show nid
                                    ++ " resulting from failure of RAID device "
                                    ++ show device
        Just host -> do
          Log.rcLog' Log.DEBUG $ "Found host: " ++ show host
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
                      -- We should always have HPI device status
                      -- information before raid_data which puts the
                      -- drive into a slot: if not then it's a bug so
                      -- at least log it.
                      --
                      -- https://seagate.slack.com/archives/castor-sspl/p1485959887000303
                      findHostStorageDevices host >>= \sdevs ->
                        unless (sdev `elem` sdevs) $ do
                          Log.rcLog' Log.ERROR $ "Raid device " ++ show sdev
                                              ++ " was not found on " ++ show host
                      return $ Just (sdev, path)
              Nothing -> do
                -- We have no device identifiers here
                -- See if we can find identifiers
                runMaybeT $ do
                  dev <- MaybeT $ findHostStorageDevices host
                        >>= filterM (flip StorageDevice.hasIdentifier $ DIRaidIdx idx)
                        >>= \case
                          [] -> do
                            Log.rcLog' Log.ERROR $ "Metadata drive at index " ++ (show idx)
                                            ++ " failed, but we have no prior information for"
                                            ++ " a drive in this position."
                            return Nothing
                          [sdev] -> return $ Just sdev
                          sdevs -> do
                            Log.rcLog' Log.WARN $ "Multiple devices with same IDs: " ++ show sdevs
                            Just <$> error "FIXME" -- mergeStorageDevices sdevs
                  path <- MaybeT $ fmap T.pack <$> StorageDevice.path dev
                  return (dev, path)

          isReassembling <- G.isConnected host Is ReassemblingRaid <$> getGraph
          if not isReassembling
          then promulgateRC $ RaidUpdate {
              ruNode = Node nid
            , ruRaidDevice = device_t
            , ruFailedComponents = fmap fst . filter (\(_,x) -> x == "_")
                                    $ catMaybes sdevs
            }
          else Log.rcLog' Log.DEBUG $ "RAID device is reassembling; not attempting "
                              ++ "further action."
      done uid
  where
    extract (HAEvent uid (RaidData nid v)) _ = return $! Just (uid, nid, v)
    extract _ _ = return Nothing

ruleMonitorExpanderReset :: Definitions RC ()
ruleMonitorExpanderReset = defineSimpleIf "monitor-expander-reset" extract $ \(uid, nid) -> do
  todo uid
  menc <- runMaybeT $ do
    host <- MaybeT $ findNodeHost (Node nid)
    MaybeT $ findHostEnclosure host
  forM_ menc $ promulgateRC . ExpanderReset
  done uid
  where
    extract (HAEvent uid (ExpanderResetInternal nid)) _ = return $! Just (uid, nid)
    extract _ _ = return Nothing

ruleThreadController :: Definitions RC ()
ruleThreadController = defineSimpleIf "monitor-thread-controller" extract $ \(uid, nid, artc) -> let
    module_name = actuatorResponseMessageActuator_response_typeThread_controllerModule_name artc
    thread_response = actuatorResponseMessageActuator_response_typeThread_controllerThread_response artc
  in do
     todo uid
     case (T.toUpper module_name, T.toUpper thread_response) of
       ("THREADCONTROLLER", "SSPL-LL SERVICE HAS STARTED SUCCESSFULLY") -> do
         mhost <- findNodeHost (Node nid)
         case mhost of
           Nothing -> Log.rcLog' Log.ERROR $ "can't find host for node " ++ show nid
           Just host -> do
             msds <- runMaybeT $ do
               lift $ findHostStorageDevices host >>=
                        traverse (\x -> do
                          liftA (x,) <$> fmap Just (StorageDevice.status x))
             encl' <- findHostEnclosure host
             Log.rcLog' Log.DEBUG $ "MSDS: " ++ show (catMaybes <$> msds, host, encl')
             forM_ msds $ \sds -> forM_ (catMaybes sds) $ \(StorageDevice serial, status) ->
               case status of
                 StorageDeviceStatus "HALON-FAILED" reason -> do
                   _ <- sendNodeCmd [Node nid] Nothing (DriveLed (T.pack serial) FaultOn)
                   sendLoggingCmd (Node nid) $ mkDiskLoggingCmd (T.pack "HALON-FAILED")
                                                                (T.pack serial)
                                                                (T.pack reason)
                 _ -> return ()
       _ -> return ()
     done uid
  where
    extract (HAEvent uid (ThreadController nid v)) _ = return $! Just (uid, nid, v)
    extract _ _ = return Nothing

-- | Send update to SSPL that the given 'StorageDevice' changed its status.
updateDriveManagerWithFailure :: StorageDevice
                              -> String
                              -> Maybe String
                              -> PhaseM RC l ()
updateDriveManagerWithFailure sdev@(StorageDevice sn) st reason = getSDevHost sdev >>= \case
  host : _ -> do
    _ <- sendLedUpdate DrivePermanentlyFailed host sdev
    nodesOnHost host >>= \case
      n : _ -> do
        sendLoggingCmd n $ mkDiskLoggingCmd (T.pack st)
                                            (T.pack sn)
                                            (maybe "unknown reason" T.pack reason)
      _ -> Log.rcLog' Log.ERROR $ "Unable to find node for " ++ show host
  _ -> Log.rcLog' Log.ERROR $ "Unable to find host for " ++ show sdev

ruleSSPLTimeout :: Definitions RC ()
ruleSSPLTimeout = defineSimpleIf "sspl-service-timeout" extract $ \(uuid, nid) -> do
  todo uuid
  mcfg <- Service.lookupInfoMsg (Node nid) sspl
  for_ mcfg $ \_ -> do
    Log.rcLog' Log.WARN
      ("SSPL didn't send any message withing timeout - restarting." :: String)
    sendSvc (getInterface sspl) nid ResetSSPLService
  done uuid
  where
    extract (HAEvent uuid (SSPLServiceTimeout nid)) _ = return $! Just (uuid, nid)
    extract _ _ = return Nothing

ruleSSPLConnectFailure :: Definitions RC ()
ruleSSPLConnectFailure = defineSimpleIf "sspl-service-connect-failure" extract $ \(uuid, nid) -> do
  todo uuid
  Log.rcLog' Log.ERROR $ "SSPL service can't connect to rabbitmq on node: " ++ show nid
  done uuid
  where
    extract (HAEvent uuid (SSPLConnectFailure nid)) _ = return $! Just (uuid, nid)
    extract _ _ = return Nothing
