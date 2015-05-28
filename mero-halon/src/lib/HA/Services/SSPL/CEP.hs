-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HA.Services.SSPL.CEP where

import HA.EventQueue.Consumer (HAEvent(..), defineHAEvent)
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
import Data.Maybe (catMaybes, listToMaybe)
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
                     -> PhaseM LoopState ()
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
                   -> PhaseM LoopState ()
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
                 -> PhaseM LoopState ()
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
  defineHAEvent "declare-channels" $
      \(HAEvent _ (DeclareChannels pid svc acs) _) -> do
          ph1 <- phase "state-1" $ do
            registerChannels svc acs
            ack pid

          start ph1

  -- SSPL Monitor drivemanager
  defineHAEvent "monitor-drivemanager" $ \(HAEvent _ (nid, mrm) _) -> do
    ph1 <- phase "state1" $ do
      host <- findNodeHost (Node nid)
      diskUUID <- liftIO $ nextRandom
      let disk_status = sensorResponseSensor_response_typeDisk_status_drivemanagerDiskStatus mrm
          encName = sensorResponseSensor_response_typeDisk_status_drivemanagerEnclosureSN mrm
          diskNum = floor . (toRealFloat :: Scientific -> Double) $
                  sensorResponseSensor_response_typeDisk_status_drivemanagerDiskNum mrm
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

    start ph1

  -- SSPL Monitor host_update
  defineHAEvent "monitor-host-update" $ \(HAEvent _ (nid, hum) _) -> do
    ph1 <- phase "state1" $
      case sensorResponseSensor_response_typeHost_updateUname hum of
        Just a -> do
          let host = Host $ T.unpack a
              node = Node nid
          registerHost host
          locateNodeOnHost node host
          case sensorResponseSensor_response_typeHost_updateIfData hum of
            Just (xs@(_:_)) -> mapM_ (registerInterface host . mkIf) ifNames
              where
                mkIf = Interface . T.unpack
                ifNames = catMaybes
                          $ fmap sensorResponseSensor_response_typeHost_updateIfDataItemIfId xs
            _ -> return ()
          liftProcess . sayRC $ "Registered host: " ++ show host
        Nothing -> return ()
    start ph1

  -- Dummy rule for handling SSPL HL commands
  defineHAEvent "systemd-restart" $ \(HAEvent _
                                              (CommandRequest (Just sr))
                                               _
                                     ) -> do
    ph1 <- phase "state1" $ do
      let
        serviceName = BL.fromStrict . T.encodeUtf8 $ commandRequestServiceRequestServiceName sr
        command = commandRequestServiceRequestCommand sr
        nodeFilter = case commandRequestServiceRequestNodes sr of
          Just foo -> T.unpack foo
          Nothing -> "."
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
    start ph1

  defineHAEvent "clustermap" $ \(HAEvent _
                                         (Devices devs)
                                         _
                                ) -> do
    ph1 <- phase "state1" $ mapM_ addDev devs
    start ph1
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
