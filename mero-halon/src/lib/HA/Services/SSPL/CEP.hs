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
-- import HA.Resources.Mero hiding (Node,Service, Process, Enclosure, Rack)
-- import HA.Resources.Mero.Note
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

import Network.CEP

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

promptRGSync :: PhaseM LoopState l ()
promptRGSync = modifyLocalGraph (liftProcess . sync)


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
ssplRulesF sspl = do
  defineSimple "declare-channels" $
      \(HAEvent uuid (DeclareChannels pid svc acs) _) -> do
          registerChannels svc acs
          ack pid
          messageProcessed uuid

  -- SSPL Monitor drivemanager
  defineSimple "monitor-drivemanager" $ \(HAEvent uuid (nid, srdm) _) -> do
      let enc = Enclosure . T.unpack
                          . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN
                          $ srdm
          diskNum = floor . (toRealFloat :: Scientific -> Double) 
                          . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum
                          $ srdm
          disk_status = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus srdm
          sn = DISerialNumber . T.unpack
                 . sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerialNumber
                 $ srdm
      phaseLog "sspl-service" "monitor-drivemanager request received"
      disk <- lookupStorageDeviceInEnclosure enc (DIIndexInEnclosure diskNum) >>= \case
        Nothing -> 
          -- Try to check if we have device with known serial number, just without location.
          lookupStorageDeviceInEnclosure enc sn >>= \case
            Just disk -> do
              identifyStorageDevice disk (DIIndexInEnclosure diskNum)
              return disk
            Nothing -> do
              phaseLog "sspl-service"
                  $ "Cant find disk in " ++ show enc ++ " at " ++ show diskNum ++ " creating new entry."
              diskUUID <- liftIO $ nextRandom
              let disk = StorageDevice diskUUID
              locateStorageDeviceInEnclosure enc disk
              mhost <- findNodeHost (Node nid)
              forM_ mhost $ \host -> locateHostInEnclosure host enc
              mapM_ (identifyStorageDevice disk) [ DIIndexInEnclosure diskNum, sn]
              syncGraph
              return disk
        Just st -> return st
      updateDriveStatus disk $ T.unpack disk_status
      isDriveRemoved <- isStorageDriveRemoved disk
      phaseLog "sspl-service"
        $ "Drive in " ++ show enc ++ " at " ++ show diskNum ++ " marked as "
           ++ (if isDriveRemoved then "removed" else "active")
      case disk_status of
        "unused_ok"
           | isDriveRemoved -> do phaseLog "sspl-service" "already removed"
                                  messageProcessed uuid
           | otherwise      -> selfMessage $ DriveRemoved uuid (Node nid) enc disk
        "failed_smart"
           | isDriveRemoved -> messageProcessed uuid
           | otherwise      -> selfMessage $ DriveFailed uuid (Node nid) enc disk
        "inuse_ok"
           | isDriveRemoved -> selfMessage $ DriveInserted uuid disk sn
           | otherwise      -> messageProcessed uuid
        s -> do let msg = InterestingEventMessage
                        $ "Error processing drive manager response: drive status "
                        <> s <> " is not known"
                sendInterestingEvent nid msg
                messageProcessed uuid

  -- Handle information messages about drive changes from HPI system.
  defineSimple "monitor-status-hpi" $ \(HAEvent uuid (nodeId, srphi) _) -> do
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
          syncGraph
          -- It may happen that we have already received "inuse_ok" status from drive manager
          -- but for a completely new device. In this case, the device has not yet been
          -- attached to mero because halon still needed the HPI information before processing
          -- the event. Check whether that was actually the case here.
          mwantUpdate <- wantsStorageDeviceReplacement sd
          case mwantUpdate of
            Just wsn | wsn == sn -> selfMessage $ DriveInserted uuid sd sn
            _   -> selfMessage $ DriveRemoved uuid nid enc sd
        Nothing -> messageProcessed uuid

  -- SSPL Monitor host_update
  defineSimple "monitor-host-update" $ \(HAEvent uuid (nid, srhu) _) -> do
      let host = Host . T.unpack
                     $ sensorResponseMessageSensor_response_typeHost_updateHostId srhu
          node = Node nid
      registerHost host
      locateNodeOnHost node host
      promptRGSync
      phaseLog "rg" $ "Registered host: " ++ show host
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
  defineSimpleIf "systemd-cmd" (\(HAEvent uuid cr _ ) _ ->
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

  defineSimpleIf "sspl-hl-node-cmd" (\(HAEvent uuid cr _ ) _ ->
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
