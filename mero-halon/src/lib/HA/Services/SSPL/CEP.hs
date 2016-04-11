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
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Maybe

import qualified Data.Aeson as Aeson
import Data.Maybe (catMaybes, listToMaybe, maybeToList, fromMaybe, isJust)
import Data.Monoid ((<>))
import Data.Scientific (Scientific, toRealFloat)
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import Data.UUID (UUID)
import Data.Binary (Binary)
import Data.Typeable (Typeable)

import Network.CEP
import GHC.Generics

import Prelude hiding (id, mapM_)

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
     let enc = Enclosure . T.unpack
                         . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN
                         $ srdm
         diskNum = floor . (toRealFloat :: Scientific -> Double)
                         . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum
                         $ srdm
         disk_status = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus srdm
         disk_reason = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskReason srdm
         sn = DISerialNumber . T.unpack
                . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerialNumber
                $ srdm
         path = DIPath . T.unpack
                . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerPathID
                $ srdm
     phaseLog "sspl-service" "monitor-drivemanager request received"
     put Local $ Just (uuid, nid, enc, diskNum, disk_status, disk_reason, sn, path)
     lookupStorageDeviceInEnclosure enc (DIIndexInEnclosure diskNum) >>= \case
       Nothing ->
         -- Try to check if we have device with known serial number, just without location.
         lookupStorageDeviceInEnclosure enc sn >>= \case
           Just disk -> do
             identifyStorageDevice disk [DIIndexInEnclosure diskNum]
             selfMessage (RuleDriveManagerDisk disk)
           Nothing -> do
             phaseLog "sspl-service"
                 $ "Cant find disk in " ++ show enc ++ " at " ++ show diskNum ++ " creating new entry."
             diskUUID <- liftIO $ nextRandom
             let disk = StorageDevice diskUUID
             locateStorageDeviceInEnclosure enc disk
             mhost <- findNodeHost (Node nid)
             forM_ mhost $ \host -> locateHostInEnclosure host enc
             identifyStorageDevice disk [DIIndexInEnclosure diskNum, sn]
             syncGraphProcess $ \self -> usend self (RuleDriveManagerDisk disk)
       Just st -> selfMessage (RuleDriveManagerDisk st)
     continue pcommit

   setPhase pcommit $ \(RuleDriveManagerDisk disk) -> do
     Just (uuid, nid, enc, diskNum, disk_status, disk_reason, sn, path) <- get Local
     updateDriveStatus disk (T.unpack disk_status) (T.unpack disk_reason)
     isDriveRemoved <- isStorageDriveRemoved disk
     phaseLog "sspl-service"
       $ "Drive in " ++ show enc ++ " at " ++ show diskNum ++ " marked as "
          ++ (if isDriveRemoved then "removed" else "active")
     case (T.toUpper disk_status, T.toUpper disk_reason) of
       ("EMPTY", "NONE")
          | isDriveRemoved -> do phaseLog "sspl-service" "already removed"
                                 messageProcessed uuid
          | otherwise      -> selfMessage $ DriveRemoved uuid (Node nid) enc disk diskNum
       ("FAILED", "SMART")
          | isDriveRemoved -> messageProcessed uuid
          | otherwise      -> selfMessage $ DriveFailed uuid (Node nid) enc disk
       ("OK", "NONE")
          | isDriveRemoved -> selfMessage $ DriveInserted uuid disk enc diskNum sn path
          | otherwise      -> messageProcessed uuid
       (s,r) -> do let msg = InterestingEventMessage $ logSSPLUnknownMessage
                         ( "{'type': 'actuatorRequest.manager_status', "
                         <> "'reason': 'Error processing drive manager response: drive status "
                         <> s <> " reason " <> r <> " is not known'}")
                   sendInterestingEvent nid msg
                   messageProcessed uuid
   start pinit Nothing

-- | Handle information messages about drive changes from HPI system.
ruleMonitorStatusHpi :: Definitions LoopState ()
ruleMonitorStatusHpi = defineSimple "monitor-status-hpi" $ \(HAEvent uuid (nodeId, srphi) _) -> do
      let _nid = Node nodeId
          sn  = DISerialNumber . T.unpack
                        . sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber
                        $ srphi
          wwn = DIWWN   . T.unpack
                        . sensorResponseMessageSensor_response_typeDisk_status_hpiWwn
                        $ srphi
          diskNum = fromInteger
                  . sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum
                  $ srphi
          idx = DIIndexInEnclosure diskNum
{-
          -- XXX: currently halon do not store additional information about drives, but this
          -- may be changed in future.
          _ident = DIUUID . T.unpack
                         . sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId
                         $ srphi
          _loc  = DIIndexInEnclosure . fromInteger
                         . sensorResponseMessageSensor_response_typeDisk_status_hpiLocation
                         $ srphi
          _drawer = DIIndexInEnclosure . fromInteger
                      . sensorResponseMessageSensor_response_typeDisk_status_hpiDrawer
                      $ srphi
-}
          host  = Host . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_hpiHostId
                       $ srphi
          serial = DISerialNumber . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber
                       $ srphi
          enc   = Enclosure . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN
                       $ srphi
      mdev <- lookupStorageDeviceInEnclosure enc idx
      locateHostInEnclosure host enc -- XXX: do we need to do that on each query?
      msd <- case mdev of
         Nothing -> do
           msnd <- lookupStorageDeviceInEnclosure enc serial
           case msnd of
             Just sd -> do
               -- We have disk in RG, but we didn't know its index in enclosure, this happens
               -- when we loaded initial data that have no information about indices.
               identifyStorageDevice sd [idx, serial]
               return Nothing
             Nothing -> do
               -- We don't have information about inserted disk in this slot yet, this could
               -- mean two different things:
               --   1. either this is completely new disk.
               --   2. we have no initial data loaded yet (currently having initial data loaded
               --      is a requirement for a service)
               -- In this case we insert new disk based on the information provided by HPI message.
               diskUUID <- liftIO $ nextRandom
               let disk = StorageDevice diskUUID
               locateStorageDeviceInEnclosure enc disk
               identifyStorageDevice disk [idx]
               return (Just disk)
         Just sd -> do
           -- We have information about disk in slot, check whether this is same disk or not.
           mident <- listToMaybe . filter (\x -> case x of DISerialNumber{} -> True ; _ -> False)
                       <$> findStorageDeviceIdentifiers sd
           case mident of
             Just serial' | serial' == serial -> return Nothing
             _ -> return (Just sd)
      forM_ msd $ \sd -> void $ attachStorageDeviceReplacement sd [sn, wwn, idx]
      syncGraphProcessMsg uuid

#ifdef USE_MERO
-- | Handle SSPL message about a service restart.
ruleMonitorServiceRestart :: Definitions LoopState ()
ruleMonitorServiceRestart = defineSimple "monitor-service-restart" $ \(HAEvent uuid (_ :: NodeId, watchdogmsg) _) -> do
  phaseLog "info" $ "Received SSPL message about service restart: " ++ show watchdogmsg
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


  case (,,,,) <$> mprocessFid <*> mcurrentPid <*> mpreviousPid <*> pure currentState <*> pure prevState of
    Nothing -> phaseLog "warn" $ "Couldn't parse " ++ show (mprocessFid, mcurrentPid, mpreviousPid)
    _ | mpreviousPid == mcurrentPid -> phaseLog "warn" $
          "Previous and current PIDs are the same, ignoring message"
    Just (processFid, currentPid, _previousPid, "active", "inactive") -> do
      svs <- M0.getM0Processes <$> getLocalGraph
      phaseLog "info" $ "Looking for fid " ++ show processFid ++ " in " ++ show svs
      let markStarting p = do
            phaseLog "info" $ "Marking " ++ show p ++ " as starting."
            modifyLocalGraph $ return . connectUniqueFrom p Has (M0.PID currentPid)
            applyStateChanges [stateSet p M0.PSStarting]
      case listToMaybe $ filter (\p -> M0.r_fid p == processFid) svs of
        Nothing -> phaseLog "warn" $ "Couldn't find process with fid " ++ show processFid
        Just p -> do
          rg <- getLocalGraph
          case (listToMaybe $ connectedTo p Is rg, listToMaybe $ connectedTo p Has rg) of
            -- Process online, mark as FAILED and wait for ONLINE from mero
            (Just M0.PSOnline, Nothing) -> do
              phaseLog "warn" $ "SSPL restart notification for online process without PID"
              markStarting p

            (Just M0.PSOnline, Just (M0.PID pid))
              | currentPid == pid -> do
                  phaseLog "warn" $
                   "Restart notification for already handled process, do nothing"
              | otherwise -> do
                  phaseLog "info" $ "Restart notification for new pid"
                  markStarting p
            -- Process starting with no PID, needs MERO-1666
            (Just M0.PSStarting, Nothing) -> markStarting p
            -- Process starting with pid, must have gotten ONLINE from
            -- mero first and now getting SSPL part of restart, mark online
            (Just M0.PSStarting, Just (M0.PID pid))
              | pid == currentPid -> do
                  phaseLog "info" $ "Received second part of restart for " ++ show p
                  applyStateChanges [stateSet p M0.PSOnline]
              | otherwise -> do
                  phaseLog "warn" $
                    "Was already waiting for notification for PID " ++ show pid
                  markStarting p
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

ruleMonitorRaidData :: Definitions LoopState ()
ruleMonitorRaidData = defineSimple "monitor-raid-data" $ \(HAEvent uuid (nid::NodeId, srrd) _) -> do
      case sensorResponseMessageSensor_response_typeRaid_dataMdstat srrd of
        Just x | x == "U_" || x == "_U" ->
          phaseLog "action" $ "Metadrive drive failed on " ++ show nid ++ "."
        _ -> return ()
      messageProcessed uuid

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
