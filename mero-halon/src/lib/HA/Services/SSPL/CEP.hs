-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HA.Services.SSPL.CEP where

import HA.EventQueue.Types (HAEvent(..))
import HA.Service hiding (configDict)
import HA.Services.SSPL.LL.Resources
import HA.RecoveryCoordinator.Mero
import HA.ResourceGraph
import HA.Resources (Cluster(..), Node(..))
import HA.Resources.Mero

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
import Data.Maybe (catMaybes, fromJust, listToMaybe, maybeToList)
import Data.Scientific (Scientific, toRealFloat)
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)

import Network.CEP

import Prelude hiding (id, mapM_)

--------------------------------------------------------------------------------
-- Primitives                                                                 --
--------------------------------------------------------------------------------

sendInterestingEvent :: NodeId
                     -> InterestingEventMessage
                     -> PhaseM LoopState l ()
sendInterestingEvent nid msg = do
  liftProcess . say $ "Sending InterestingEventMessage"
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp IEMChannel rg

  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan msg
    _ -> liftProcess $ sayRC "Cannot find IEM channel!"

sendSystemdCmd :: NodeId
               -> SystemdCmd
               -> PhaseM LoopState l ()
sendSystemdCmd nid req = do
  liftProcess . say $ "Sending Systemd request" ++ show req
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp CommandChannel rg
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan (makeSystemdMsg req)
    _ -> liftProcess $ sayRC "Cannot find systemd channel!"

sendNodeCmd :: NodeId
            -> NodeCmd
            -> PhaseM LoopState l ()
sendNodeCmd nid req = do
  liftProcess . say $ "Sending node actuator request" ++ show req
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp CommandChannel rg
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan (makeNodeMsg req)
    _ -> liftProcess $ sayRC "Cannot find command channel!"

registerChannels :: ServiceProcess SSPLConf
                 -> ActuatorChannels
                 -> PhaseM LoopState l ()
registerChannels svc acs = modifyLocalGraph $ \rg -> do
    liftProcess . say $ "Register channels"
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
        removeOldChan >>>
        newResource chan >>>
        connect svc r chan
      where
        oldChan :: Graph -> [Channel b]
        oldChan rg = connectedTo svc r rg
        removeOldChan = \rg -> case oldChan rg of
          [a] -> disconnect svc r a rg
          _ -> rg
        chan = Channel sp

--------------------------------------------------------------------------------
-- Rules                                                                      --
--------------------------------------------------------------------------------

ssplRulesF :: Service SSPLConf -> Definitions LoopState ()
ssplRulesF sspl = do
  defineSimple "declare-channels" $
      \(HAEvent _ (DeclareChannels pid svc acs) _) -> do
          registerChannels svc acs
          ack pid

  -- SSPL Monitor drivemanager
  defineSimpleIf "monitor-drivemanager" (\(HAEvent _ (nid, mrm) _) _ ->
    return $ sensorResponseMessageSensor_response_typeDisk_status_drivemanager mrm
         >>= return . (nid,)
    ) $ \(nid, mrm) -> do
      host <- findNodeHost (Node nid)
      diskUUID <- liftIO $ nextRandom
      let disk_status = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus mrm
          encName = sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN mrm
          diskNum = floor . (toRealFloat :: Scientific -> Double) $
                  sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum mrm
          enc = Enclosure $ T.unpack encName
          disk = StorageDevice diskUUID

      locateStorageDeviceInEnclosure enc disk
      identifyStorageDevice disk $ DeviceIdentifier "slot" (IdentInt diskNum)
      updateDriveStatus disk $ T.unpack disk_status
      mapM_ (\h -> do
            locateHostInEnclosure h enc
            -- Find any existing (logical) devices and link them
            hostDevs <- findHostStorageDevices h
                      >>= filterM (flip hasStorageDeviceIdentifier
                                  (DeviceIdentifier "slot" (IdentInt diskNum)))
            mapM_ (\d -> mergeStorageDevices [d,disk]) hostDevs
            ) host

      liftProcess . sayRC $ "Registered drive"
      when (disk_status == "inuse_removed") $ do
        let msg = InterestingEventMessage "Bunnies, bunnies it must be bunnies."
        sendInterestingEvent nid msg
      when (disk_status == "unused_ok") $ do
        let msg = InterestingEventMessage . T.pack
                  $  "Drive powered off: \n\t"
                  ++ show enc
                  ++ "\n\t"
                  ++ show disk
        sendInterestingEvent nid msg

  -- SSPL Monitor host_update
  defineSimpleIf "monitor-host-update" (\(HAEvent _ (nid, hum) _) _ ->
      return $ sensorResponseMessageSensor_response_typeHost_update hum
           >>= sensorResponseMessageSensor_response_typeHost_updateHostId
           >>= return . (nid,)
    ) $ \(nid, a) -> do
      let host = Host $ T.unpack a
          node = Node nid
      registerHost host
      locateNodeOnHost node host
      liftProcess . sayRC $ "Registered host: " ++ show host

  -- SSPL Monitor interface data
  defineSimpleIf "monitor-if-update" (\(HAEvent _ (_ :: NodeId, hum) _) _ ->
      return $ sensorResponseMessageSensor_response_typeIf_data hum
    ) $ \(SensorResponseMessageSensor_response_typeIf_data hn _ ifs') ->
      let
        host = Host . T.unpack $ fromJust hn
        ifs = join $ maybeToList ifs' -- Maybe List, for some reason...
        addIf i = registerInterface host . Interface . T.unpack . fromJust
          $ sensorResponseMessageSensor_response_typeIf_dataInterfacesItemIfId i
      in do
        phaseLog "action" $ "Adding interfaces to host " ++ show host
        forM_ ifs addIf

  -- Dummy rule for handling SSPL HL commands
  defineSimpleIf "systemd-cmd" (\(HAEvent _ cr _ ) _ ->
    return $ commandRequestMessageServiceRequest
              . commandRequestMessage
              $ cr
    ) $ \sr ->
      let
        serviceName = commandRequestMessageServiceRequestServiceName sr
        command = commandRequestMessageServiceRequestCommand sr
        nodeFilter = case commandRequestMessageServiceRequestNodes sr of
          Just foo -> T.unpack foo
          Nothing -> "." in
      case command of
        -- Aeson.String "start" -> liftProcess $ say "Unsupported."
        -- Aeson.String "stop" -> liftProcess $ say "Unsupported."
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

  defineSimpleIf "sspl-hl-node-cmd" (\(HAEvent _ cr _ ) _ ->
    return $ commandRequestMessageNodeStatusChangeRequest
              . commandRequestMessage
              $ cr
    ) $ \sr ->
      let
        command = commandRequestMessageNodeStatusChangeRequestCommand sr
        nodeFilter = case commandRequestMessageNodeStatusChangeRequestNodes sr of
          Just foo -> T.unpack foo
          Nothing -> "."
      in do
        (Node actuationNode) <- fmap head
            $ findHosts ".*"
          >>= filterM (hasHostStatusFlag HS_POWERED)
          >>= mapM nodesOnHost
          >>= return . join
          >>= filterM (\a -> isServiceRunning a sspl)
        hosts <- fmap catMaybes
                $ findHosts nodeFilter
              >>= mapM findBMCAddress
        case command of
          Aeson.String "poweroff" -> do
            phaseLog "action" $ "Powering off hosts " ++ (show hosts)
            forM_ hosts $ \(nodeIp) -> do
              sendNodeCmd actuationNode $ IPMICmd IPMI_OFF (T.pack nodeIp)
          Aeson.String "poweron" -> do
            phaseLog "action" $ "Powering on hosts " ++ (show hosts)
            forM_ hosts $ \(nodeIp) -> do
              sendNodeCmd actuationNode $ IPMICmd IPMI_ON (T.pack nodeIp)
          x -> liftProcess . say $ "Unsupported node command: " ++ show x

  defineSimple "clustermap" $ \(HAEvent _
                                        (Devices devs)
                                        _
                                      ) ->
    mapM_ addDev devs
    where
      addDev (DevId mid fn sl hn) = do
          diskUUID <- liftIO $ nextRandom
          let dev = StorageDevice diskUUID
          locateStorageDeviceOnHost host dev
          identifyStorageDevice dev (DeviceIdentifier "iosid" (IdentInt mid))
          identifyStorageDevice dev (DeviceIdentifier "slot" (IdentInt sl))
          identifyStorageDevice dev (DeviceIdentifier "filename" (IdentString fn))
          -- | Find existing storage devices and link them
          menc <- findHostEnclosure host
          mapM_ (\enc -> do
                  drives <- findEnclosureStorageDevices enc
                        >>= filterM (flip hasStorageDeviceIdentifier $
                                      DeviceIdentifier "slot" (IdentInt sl)
                                    )
                  mapM_ (\d -> mergeStorageDevices [dev, d]) drives
                ) menc
        where
          host = Host hn
