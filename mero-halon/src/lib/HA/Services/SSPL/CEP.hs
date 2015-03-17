-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings #-}

module HA.Services.SSPL.CEP where

import HA.EventQueue.Consumer (HAEvent(..), defineHAEvent)
import HA.Service hiding (configDict)
import HA.Services.SSPL.Resources
import HA.RecoveryCoordinator.Mero
import HA.ResourceGraph
import HA.Resources (Cluster(..), Node(..))
import HA.Resources.Mero

import SSPL.Bindings

import Control.Arrow ((>>>))
import Control.Category (id)
import Control.Distributed.Process
  ( NodeId
  , sendChan
  , say
  )

import Control.Monad.State.Strict hiding (mapM_)

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
      _ -> liftProcess $ sayRC "Cannot find anything!"

registerChannels :: ServiceProcess SSPLConf
                 -> ActuatorChannels
                 -> CEP LoopState ()
registerChannels svc acs = do
    ls <- get
    liftProcess . say $ "Register channels"
    let chan = Channel $ iemPort acs
        rg' = newResource svc >>>
              newResource chan >>>
              connect svc IEMChannel chan $ lsGraph ls

    put ls { lsGraph = rg' }

--------------------------------------------------------------------------------
-- Rules                                                                      --
--------------------------------------------------------------------------------

ssplRules :: RuleM LoopState ()
ssplRules = do
    defineHAEvent id $
        \(HAEvent _ (DeclareChannels pid svc acs) _) -> do
            registerChannels svc acs
            ack pid

    -- SSPL Monitor drivemanager
    defineHAEvent id $ \(HAEvent _ (nid, mrm) _) -> do
      let disk_status = monitorResponseMonitor_msg_typeDisk_status_drivemanagerDiskStatus mrm
          encName = monitorResponseMonitor_msg_typeDisk_status_drivemanagerEnclosureSN mrm
          diskNum = monitorResponseMonitor_msg_typeDisk_status_drivemanagerDiskNum mrm
          enc = Enclosure $ T.unpack encName
          disk = StorageDevice . floor . (toRealFloat :: Scientific -> Double)
                  $ diskNum

      registerDrive enc disk
      updateDriveStatus disk $ T.unpack disk_status
      liftProcess . sayRC $ "Registered drive"
      when (disk_status == "inuse_removed") $ do
        let msg = InterestingEventMessage "Bunnies, bunnies it must be bunnies."
        sendInterestingEvent nid msg

    -- SSPL Monitor host_update
    defineHAEvent id $ \(HAEvent _ (nid, hum) _) ->
      case monitorResponseMonitor_msg_typeHost_updateUname hum of
        Just a -> let
            host = Host $ T.unpack a
            node = Node nid
          in do
            registerHost host
            locateNodeOnHost node host
            case monitorResponseMonitor_msg_typeHost_updateIfData hum of
              Just (xs@(_:_)) -> mapM_ (registerInterface host . mkIf) ifNames
                where
                  mkIf = Interface . T.unpack
                  ifNames = catMaybes
                            $ fmap monitorResponseMonitor_msg_typeHost_updateIfDataItemIfId xs
              _ -> return ()
            liftProcess . sayRC $ "Registered host: " ++ show host
        Nothing -> return ()
