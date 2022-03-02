-- |
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Handle commands that could be sent to the cluster.
--
module HA.RecoveryCoordinator.Castor.Commands
  ( rules
  ) where

import           Control.Category
import           Control.Distributed.Process
import           Data.Maybe (listToMaybe)
import           Data.UUID.V4 (nextRandom)
import           HA.RecoveryCoordinator.Castor.Commands.Events
import qualified HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Runs(..))
import qualified HA.Resources.Castor as Cas
import           Network.CEP

-- | List of rules.
rules :: Definitions RC ()
rules = sequence_
  [ driveNew
  , drivePresence
  , driveStatus
  ]

-- | Update drive presence, this command is completely analogus to the
-- SSPL HPI notifications but is done from developer console.
drivePresence :: Definitions RC ()
drivePresence = defineSimpleTask "castor::command::update-drive-presence" $
  \(CommandStorageDevicePresence serial slot isInstalled isPowered chan) -> do
     let sd = Cas.StorageDevice serial
     let Cas.Slot enc _idx = slot
     rg <- getGraph
     if G.isConnected Cluster Has sd rg
     then let nodes = do host :: Cas.Host <- G.connectedTo enc Has rg
                         G.connectedTo host Runs rg
          in case listToMaybe nodes of
               Nothing -> liftProcess $ sendChan chan StorageDevicePresenceErrorNoSuchEnclosure
               Just node -> do
                 uuid <- liftIO $ nextRandom
                 Drive.updateStorageDevicePresence uuid node sd slot isInstalled (Just isPowered)
                 liftProcess $ sendChan chan StorageDevicePresenceUpdated
     else liftProcess $ sendChan chan StorageDevicePresenceErrorNoSuchDevice

-- | Update status of the storage device. This command is analogus to
-- the SSPL Drive-Manager request but run from the developer console.
driveStatus :: Definitions RC ()
driveStatus = defineSimpleTask "castor::command::update-drive-status" $
  \(CommandStorageDeviceStatus serial slot status reason chan) -> do
      let sd = Cas.StorageDevice serial
      let Cas.Slot enc _idx = slot
      rg <- getGraph
      if G.isConnected Cluster Has sd rg
      then let nodes = do host :: Cas.Host <- G.connectedTo enc Has rg
                          G.connectedTo host Runs rg
           in case listToMaybe nodes of
                Nothing -> liftProcess $ sendChan chan StorageDeviceStatusErrorNoSuchEnclosure
                Just node -> do
                  uuid <- liftIO nextRandom
                  _ <- Drive.updateStorageDeviceStatus uuid node sd slot status reason
                  liftProcess $ sendChan chan StorageDeviceStatusUpdated
      else liftProcess $ sendChan chan StorageDeviceStatusErrorNoSuchDevice

-- | Create new drive and store that in RG.
driveNew :: Definitions RC ()
driveNew = defineSimpleTask "castor::command::new-drive" $
  \(CommandStorageDeviceCreate serial path chan) -> do
     let sd = Cas.StorageDevice serial
     rg <- getGraph
     if not $ G.isConnected Cluster Has sd rg
     then do modifyGraph $ G.connect Cluster Has sd
                      >>> G.connect sd Has (Cas.DIPath path)
             liftProcess $ sendChan chan StorageDeviceCreated
     else liftProcess $ sendChan chan StorageDeviceErrorAlreadyExists
