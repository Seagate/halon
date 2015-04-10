-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HA.Services.SSPL.CEP where

import HA.EventQueue.Consumer (HAEvent(..), defineHAEvent)
import HA.EventQueue.Types (EventId(..))
import HA.Service hiding (configDict)
import HA.Services.SSPL.LL.Resources
import HA.Services.SSPL.HL.Resources
import HA.RecoveryCoordinator.Mero
import HA.ResourceGraph
import HA.Resources (Cluster(..), Node(..))
import HA.Resources.Mero

import SSPL.Bindings

import Control.Arrow ((>>>))
import Control.Category (id)
import Control.Distributed.Process
  ( NodeId
  , SendPort
  , processNodeId
  , sendChan
  , say
  )

import Control.Monad.State.Strict hiding (mapM_)

import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Foldable (mapM_)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Scientific (Scientific, toRealFloat)
import qualified Data.Text as T

import Network.CEP

import Prelude hiding (id, mapM_)

--------------------------------------------------------------------------------
-- Primitives                                                                 --
--------------------------------------------------------------------------------

sendInterestingEvent :: NodeId
                     -> InterestingEventMessage
                     -> CEP LoopState ()
sendInterestingEvent nid msg = do
  liftProcess . say $ "Sending InterestingEventMessage"
  rg <- gets lsGraph
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
                   -> CEP LoopState ()
sendSystemdRequest nid req = do
  liftProcess . say $ "Sending Systemd request" ++ show req
  rg <- gets lsGraph
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
                 -> CEP LoopState ()
registerChannels svc acs = do
    ls <- get
    liftProcess . say $ "Register channels"
    let rg' =   registerChannel IEMChannel (iemPort acs)
            >>> registerChannel SystemdChannel (systemdPort acs)
            $   lsGraph ls
    put ls { lsGraph = rg' }
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

ssplRules :: RuleM LoopState ()
ssplRules = do
  defineHAEvent "declare-channels" id $
      \(HAEvent _ (DeclareChannels pid svc acs) _) -> do
          registerChannels svc acs
          ack pid

  -- SSPL Monitor drivemanager
  defineHAEvent "monitor-drivemanager" id $ \(HAEvent _ (nid, mrm) _) -> do
    let disk_status = sensorResponseSensor_response_typeDisk_status_drivemanagerDiskStatus mrm
        encName = sensorResponseSensor_response_typeDisk_status_drivemanagerEnclosureSN mrm
        diskNum = sensorResponseSensor_response_typeDisk_status_drivemanagerDiskNum mrm
        enc = Enclosure $ T.unpack encName
        disk = StorageDevice . floor . (toRealFloat :: Scientific -> Double)
                $ diskNum

    registerDrive enc disk
    updateDriveStatus disk $ T.unpack disk_status
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
  defineHAEvent "monitor-host-update" id $ \(HAEvent _ (nid, hum) _) ->
    case sensorResponseSensor_response_typeHost_updateUname hum of
      Just a -> let
          host = Host $ T.unpack a
          node = Node nid
        in do
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

  -- Dummy rule for handling SSPL HL commands
  defineHAEvent "systemd-restart" id $ \(HAEvent (EventId pid _) (SSPLHLCmd msg) _) -> let
      nid = processNodeId pid
    in do
      sendSystemdRequest nid $ SystemdRequest msg "restart"
      sendInterestingEvent nid $
        InterestingEventMessage ("Restarting service " `BL.append` msg)

