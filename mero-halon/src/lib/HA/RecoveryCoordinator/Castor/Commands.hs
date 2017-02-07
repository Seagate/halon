-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
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
import           HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           Network.CEP

-- | List of rules.
rules :: Definitions RC ()
rules = sequence_ 
  [ driveNew
  , drivePresence
  ]

-- | Update drive presence, this command is completely analogus to the
-- SSPL HPI notifications but is done from developer console.
drivePresence :: Definitions RC ()
drivePresence = defineSimpleTask "castor::command::update-drive-presence" $
  \(CommandStorageDevicePresence serial slot isInstalled isPowered chan) -> do
     let sd = StorageDevice serial
     let Slot enc _idx = slot
     rg <- getLocalGraph
     if isConnected Cluster Has sd rg
     then let nodes = do host :: Host <- G.connectedTo enc Has rg
                         G.connectedTo host Runs rg
          in case listToMaybe nodes of
               Nothing -> liftProcess $ sendChan chan StorageDevicePresenceErrorNoSuchEnclosure
               Just node -> do
                 uuid <- liftIO $ nextRandom
                 Drive.updateStorageDevicePresence uuid node sd slot isInstalled isPowered
                 liftProcess $ sendChan chan StorageDevicePresenceUpdated
     else liftProcess $ sendChan chan StorageDevicePresenceErrorNoSuchDevice

-- | Create new drive and store that in RG.
driveNew :: Definitions RC ()
driveNew = defineSimpleTask "castor::command::new-drive" $
  \(CommandStorageDeviceCreate serial path chan) -> do
     let sd = StorageDevice serial
     rg <- getLocalGraph
     if not $ isConnected Cluster Has sd rg
     then do modifyGraph $ G.connect Cluster Has sd
                      >>> G.connect sd Has (DIPath path)
             liftProcess $ sendChan chan StorageDeviceCreated 
     else liftProcess $ sendChan chan StorageDeviceErrorAlreadyExists
