-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HA.Services.SSPL.CEP where

import HA.EventQueue.Consumer
  ( HAEvent(..)
  , defineSimpleHAEvent
  , defineSimpleHAEventIf
  )
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
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Maybe (listToMaybe)
import Data.Scientific (Scientific, toRealFloat)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
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

sendSystemdRequest :: NodeId
                   -> SystemdRequest
                   -> PhaseM LoopState l ()
sendSystemdRequest nid req = do
  liftProcess . say $ "Sending Systemd request" ++ show req
  rg <- getLocalGraph
  let
    node = Node nid
    chanm = do
      s <- listToMaybe $ (connectedTo Cluster Supports rg :: [Service SSPLConf])
      sp <- runningService node s rg
      listToMaybe $ connectedTo sp SystemdChannel rg
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan req
    _ -> liftProcess $ sayRC "Cannot find systemd channel!"

registerChannels :: ServiceProcess SSPLConf
                 -> ActuatorChannels
                 -> PhaseM LoopState l ()
registerChannels svc acs = modifyLocalGraph $ \rg -> do
    liftProcess . say $ "Register channels"
    let rg' =   registerChannel IEMChannel (iemPort acs)
            >>> registerChannel SystemdChannel (systemdPort acs)
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
  defineSimpleHAEvent "declare-channels" $
      \(HAEvent _ (DeclareChannels pid svc acs) _) -> do
          registerChannels svc acs
          ack pid

  -- SSPL Monitor drivemanager
  defineSimpleHAEvent "monitor-drivemanager" $ \(HAEvent _ (nid, mrm) _) -> do
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
      let msg = InterestingEventMessage . BL.pack
                $  "Drive powered off: \n\t"
                ++ show enc
                ++ "\n\t"
                ++ show disk
      sendInterestingEvent nid msg

  -- SSPL Monitor host_update
  defineSimpleHAEventIf "monitor-host-update" (\(HAEvent _ (nid, hum) _) _ ->
      return . fmap (\a -> (nid, a))
        $ sensorResponseMessageSensor_response_typeHost_updateHostId hum
    ) $ \(nid, a) -> do
      let host = Host $ T.unpack a
          node = Node nid
      registerHost host
      locateNodeOnHost node host
      liftProcess . sayRC $ "Registered host: " ++ show host

  -- Dummy rule for handling SSPL HL commands
  defineSimpleHAEventIf "systemd-restart" (\(HAEvent _ cr _ ) _ ->
    return $ commandRequestMessageServiceRequest
              . commandRequestMessage
              $ cr
    ) $ \sr ->
      let
        serviceName = BL.fromStrict . T.encodeUtf8 $ commandRequestMessageServiceRequestServiceName sr
        command = commandRequestMessageServiceRequestCommand sr
        nodeFilter = case commandRequestMessageServiceRequestNodes sr of
          Just foo -> T.unpack foo
          Nothing -> "." in
      case command of
        Aeson.String "start" -> liftProcess $ say "Unsupported."
        Aeson.String "stop" -> liftProcess $ say "Unsupported."
        Aeson.String "restart" -> do
          nodes <- findHosts nodeFilter
                    >>= mapM nodesOnHost
                    >>= return . join
                    >>= filterM (\a -> isServiceRunning a sspl)
          phaseLog "action" $ "Restarting " ++ (BL.unpack serviceName)
                          ++ " on nodes " ++ (show nodes)
          forM_ nodes $ \(Node nid) -> do
            sendSystemdRequest nid $ SystemdRequest serviceName "restart"
            sendInterestingEvent nid $
              InterestingEventMessage ("Restarting service " `BL.append` serviceName)
        Aeson.String "enable" -> liftProcess $ say "Unsupported."
        Aeson.String "disable" -> liftProcess $ say "Unsupported."
        Aeson.String "status" -> liftProcess $ say "Unsupported."
        _ -> liftProcess $ say "Unsupported."

  defineSimpleHAEvent "clustermap" $ \(HAEvent _
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
