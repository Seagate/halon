-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Manipulation of drive entities in the resource graph. Split out here
-- to avoid a cycle.
module HA.RecoveryCoordinator.Castor.Drive.Actions.Graph
  ( getAllSDev
  , lookupStorageDevice
  , lookupStorageDeviceSDev
  , lookupDiskSDev
  , lookupSDevDisk
    -- * Attach/detach
  , attachStorageDeviceToSDev
  ) where

import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.ResourceGraph as G
import           HA.Resources.Castor (StorageDevice)
import qualified HA.Resources.Mero as M0

import           Network.CEP

-- | Find every 'M0.SDev' in the 'Res.Cluster'.
getAllSDev :: G.Graph -> [M0.SDev]
getAllSDev rg =
  [ sdev
  | site :: M0.Site <- G.connectedTo (M0.getM0Root rg) M0.IsParentOf rg
  , rack :: M0.Rack <- G.connectedTo site M0.IsParentOf rg
  , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
  , ctrl :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
  , disk :: M0.Disk <- G.connectedTo ctrl M0.IsParentOf rg
  , Just (sdev :: M0.SDev) <- [G.connectedFrom M0.IsOnHardware disk rg]
  ]

-- | Find 'StorageDevice' associated with the given 'M0.SDev'.
lookupStorageDevice :: M0.SDev -> PhaseM RC l (Maybe StorageDevice)
lookupStorageDevice sdev = do
    rg <- getGraph
    return $ do
      dev <- G.connectedTo sdev M0.IsOnHardware rg
      G.connectedTo (dev :: M0.Disk) M0.At rg

-- | Return the Mero SDev associated with the given storage device
lookupStorageDeviceSDev :: StorageDevice -> PhaseM RC l (Maybe M0.SDev)
lookupStorageDeviceSDev sdev = do
  rg <- getGraph
  return $ do
    disk <- G.connectedFrom M0.At sdev rg
    G.connectedFrom M0.IsOnHardware (disk :: M0.Disk) rg

-- | Connect 'StorageDevice' with corresponcing 'M0.SDev'.
attachStorageDeviceToSDev :: StorageDevice -> M0.SDev -> PhaseM RC l ()
attachStorageDeviceToSDev sdev m0sdev = do
  rg <- getGraph
  case G.connectedTo m0sdev M0.IsOnHardware rg of
    Nothing -> return ()
    Just disk -> modifyGraph $ G.connect (disk::M0.Disk) M0.At sdev

-- | Find 'M0.Disk' associated with the given 'M0.SDev'.
lookupSDevDisk :: M0.SDev -> PhaseM RC l (Maybe M0.Disk)
lookupSDevDisk sdev =
    G.connectedTo sdev M0.IsOnHardware <$> getGraph

-- | Given a 'M0.Disk', find the 'M0.SDev' attached to it.
lookupDiskSDev :: M0.Disk -> PhaseM RC l (Maybe M0.SDev)
lookupDiskSDev disk =
    G.connectedFrom M0.IsOnHardware disk <$> getGraph
