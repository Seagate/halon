-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP                 #-}

module HA.Services.SSPL.CEP where

import HA.EventQueue.Types (HAEvent(..))
import HA.Service hiding (configDict)
import HA.Services.SSPL.LL.Resources
import HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.Events.Drive
import HA.ResourceGraph
import HA.Resources (Cluster(..), Node(..))
import HA.Resources.Castor
#ifdef USE_MERO
import Mero.Notification
#endif

import SSPL.Bindings

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

import qualified Data.Aeson as Aeson
import Data.Maybe (catMaybes, listToMaybe)
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

-- | Send command to nodecontroller. Reply will be received as a
-- HAEvent CommandAck. Where UUID will be set to UUID value if passed, and
-- any random value otherwise.
sendNodeCmd :: NodeId
            -> Maybe UUID
            -> NodeCmd
            -> PhaseM LoopState l ()
sendNodeCmd nid muuid req = do
  phaseLog "action" $ "Sending node actuator request" ++ show req
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp CommandChannel rg
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan (muuid, makeNodeMsg req)
    _ -> phaseLog "warning" "Cannot find command channel!"

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
        connectUnique svc r chan
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
                         . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosure_serial_number
                         $ srdm
         diskNum = floor . (toRealFloat :: Scientific -> Double)
                         . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDisk
                         $ srdm
         disk_status = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerStatus srdm
         reason = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerReason srdm
         sn = DISerialNumber . T.unpack
                . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerial_number
                $ srdm
     phaseLog "sspl-service" "monitor-drivemanager request received"
     put Local $ Just (uuid, nid, enc, diskNum, disk_status, reason, sn)
     lookupStorageDeviceInEnclosure enc (DIIndexInEnclosure diskNum) >>= \case
       Nothing ->
         -- Try to check if we have device with known serial number, just without location.
         lookupStorageDeviceInEnclosure enc sn >>= \case
           Just disk -> do
             identifyStorageDevice disk (DIIndexInEnclosure diskNum)
             selfMessage (RuleDriveManagerDisk disk)
           Nothing -> do
             phaseLog "sspl-service"
                 $ "Cant find disk in " ++ show enc ++ " at " ++ show diskNum ++ " creating new entry."
             diskUUID <- liftIO $ nextRandom
             let disk = StorageDevice diskUUID
             locateStorageDeviceInEnclosure enc disk
             mhost <- findNodeHost (Node nid)
             forM_ mhost $ \host -> locateHostInEnclosure host enc
             mapM_ (identifyStorageDevice disk) [DIIndexInEnclosure diskNum, sn]

             syncGraphProcess $ \self -> usend self (RuleDriveManagerDisk disk)
       Just st -> selfMessage (RuleDriveManagerDisk st)
     continue pcommit

   setPhase pcommit $ \(RuleDriveManagerDisk disk) -> do
     Just (uuid, nid, enc, diskNum, disk_status, reason, sn) <- get Local
     updateDriveStatus disk $ T.unpack disk_status
     isDriveRemoved <- isStorageDriveRemoved disk
     phaseLog "sspl-service"
       $ "Drive in " ++ show enc ++ " at " ++ show diskNum ++ " marked as "
          ++ (if isDriveRemoved then "removed" else "active")
     case (T.toUpper disk_status, T.toUpper reason) of
       ("EMPTY", "NONE")
          | isDriveRemoved -> do phaseLog "sspl-service" "already removed"
                                 messageProcessed uuid
          | otherwise      -> selfMessage $ DriveRemoved uuid (Node nid) enc disk
       ("FAILED", "SMART")
          | isDriveRemoved -> messageProcessed uuid
          | otherwise      -> selfMessage $ DriveFailed uuid (Node nid) enc disk
       ("OK", "NONE")
          | isDriveRemoved -> selfMessage $ DriveInserted uuid disk sn
          | otherwise      -> messageProcessed uuid
       s -> do let msg = InterestingEventMessage
                       $ "Error processing drive manager response: drive status "
                       <> fst s <> "_" <> snd s <> " is not known"
               sendInterestingEvent nid msg
               messageProcessed uuid
   start pinit Nothing

-- | Handle information messages about drive changes from HPI system.
ruleMonitorStatusHpi :: Definitions LoopState ()
ruleMonitorStatusHpi = defineSimple "monitor-status-hpi" $ \(HAEvent uuid (nodeId, srphi) _) -> do
      let nid = Node nodeId
          sn  = DISerialNumber . T.unpack
                        . sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber
                        $ srphi
          wwn = DIWWN   . T.unpack
                        . sensorResponseMessageSensor_response_typeDisk_status_hpiWwn
                        $ srphi
          ident = DIUUID . T.unpack
                         . sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId
                         $ srphi
          loc   = DIIndexInEnclosure . fromInteger
                         . sensorResponseMessageSensor_response_typeDisk_status_hpiLocation
                         $ srphi
          host  = Host . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_hpiHostId
                       $ srphi
          serial = DISerialNumber . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber
                       $ srphi
          enc   = Enclosure . T.unpack
                       . sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN
                       $ srphi
      mdev <- lookupStorageDeviceInEnclosure enc loc
      locateHostInEnclosure host enc -- XXX: do we need to do that on each query?
      msd <- case mdev of
         Nothing -> do
           mwsd <- lookupStorageDeviceInEnclosure enc wwn
           case mwsd of
             Just sd -> do
               -- We have disk in RG, but we didn't know its index in enclosure, this happens
               -- when we loaded initial data that have no information about indices.
               identifyStorageDevice sd loc
               identifyStorageDevice sd serial
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
               identifyStorageDevice disk loc
               return (Just disk)
         Just sd -> do
           -- We have information about disk in slot.
           mident <- listToMaybe . filter (\x -> case x of DIWWN{} -> True ; _ -> False)
                       <$> findStorageDeviceIdentifiers sd
           case mident of
             Just wwn' | wwn' == wwn -> return Nothing
             _ -> return (Just sd)
      case msd of
        Just sd -> do
          _ <- attachStorageDeviceReplacement sd [sn, wwn, ident, loc]
          -- It may happen that we have already received "OK_None" status from drive manager
          -- but for a completely new device. In this case, the device has not yet been
          -- attached to mero because halon still needed the HPI information before processing
          -- the event. Check whether that was actually the case here.
          mwantUpdate <- wantsStorageDeviceReplacement sd
          case mwantUpdate of
            Just wsn | wsn == sn ->
              syncGraphProcess $ \self -> usend self $ DriveInserted uuid sd sn
            _   ->
              syncGraphProcess $ \self -> usend self $ DriveRemoved uuid nid enc sd
        Nothing -> messageProcessed uuid

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
ruleMonitorRaidData = defineSimple "monitor-raid-data" $ \(HAEvent uuid (nid, srrd) _) -> let
      host = sensorResponseMessageSensor_response_typeRaid_dataHostId srrd
    in do
      case sensorResponseMessageSensor_response_typeRaid_dataMdstat srrd of
        Just x | x == "U_" || x == "_U" -> do
          sendInterestingEvent nid $ InterestingEventMessage (
            "Metadata drive failure on host " `T.append` host
            )
          phaseLog "action" $ "Sending IEM for metadata drive failure."
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
            sendInterestingEvent nid $
              InterestingEventMessage ("Starting service " `T.append` serviceName)
        Aeson.String "stop" -> do
          nodes <- findHosts nodeFilter
                    >>= mapM nodesOnHost
                    >>= return . join
                    >>= filterM (\a -> isServiceRunning a sspl)
          phaseLog "action" $ "Stopping " ++ (T.unpack serviceName)
                          ++ " on nodes " ++ (show nodes)
          forM_ nodes $ \(Node nid) -> do
            sendSystemdCmd nid $ SystemdCmd serviceName SERVICE_STOP
            sendInterestingEvent nid $
              InterestingEventMessage ("Stopping service " `T.append` serviceName)
        Aeson.String "restart" -> do
          nodes <- findHosts nodeFilter
                    >>= mapM nodesOnHost
                    >>= return . join
                    >>= filterM (\a -> isServiceRunning a sspl)
          phaseLog "action" $ "Restarting " ++ (T.unpack serviceName)
                          ++ " on nodes " ++ (show nodes)
          forM_ nodes $ \(Node nid) -> do
            sendSystemdCmd nid $ SystemdCmd serviceName SERVICE_RESTART
            sendInterestingEvent nid $
              InterestingEventMessage ("Restarting service " `T.append` serviceName)
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
