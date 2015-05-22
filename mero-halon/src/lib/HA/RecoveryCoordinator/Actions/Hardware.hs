-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}

module HA.RecoveryCoordinator.Actions.Hardware
  ( -- * Host related functions
    findHosts
  , findHostEnclosure
  , findNodeHost
  , locateHostInEnclosure
  , locateNodeOnHost
  , registerHost
  , nodesOnHost
    -- * Interface related functions
  , registerInterface
    -- * Drive related functions
  , driveStatus
  , findEnclosureStorageDevices
  , findHostStorageDevices
  , findStorageDeviceIdentifiers
  , hasStorageDeviceIdentifier
  , identifyStorageDevice
  , locateStorageDeviceInEnclosure
  , locateStorageDeviceOnHost
  , mergeStorageDevices
  , updateDriveStatus
) where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Mero

import Control.Category ((>>>))
import Control.Distributed.Process (liftIO)

import Data.UUID.V4 (nextRandom)

import Network.CEP

import Text.Regex.TDFA ((=~))

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find the host running the given node
findNodeHost :: Node
             -> PhaseM LoopState (Maybe Host)
findNodeHost node =  do
  phaseLog "rg-query" $ "Looking for host running " ++ show node
  g <- getLocalGraph
  return $ case G.connectedFrom Runs node g of
    [h] -> Just h
    _ -> Nothing

-- | Find the enclosure containing the given host.
findHostEnclosure :: Host
                  -> PhaseM LoopState (Maybe Enclosure)
findHostEnclosure host = do
  phaseLog "rg-query" $ "Looking for enclosure containing " ++ show host
  g <- getLocalGraph
  return $ case G.connectedFrom Has host g of
    [h] -> Just h
    _ -> Nothing

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String
          -> PhaseM LoopState [Host]
findHosts regex = do
  phaseLog "rg-query" $ "Looking for hosts matching regex " ++ regex
  g <- getLocalGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> PhaseM LoopState [Node]
nodesOnHost host = do
  phaseLog "rg-query" $ "Looking for nodes on host " ++ show host
  fmap (G.connectedTo host Runs) getLocalGraph

-- | Register a new host in the system.
registerHost :: Host
             -> PhaseM LoopState ()
registerHost host = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering host: "
              ++ show host

  let rg' = G.newResource host
        >>> G.connect Cluster Has host
          $ rg
  return rg'

-- | Record that a host is running in an enclosure.
locateHostInEnclosure :: Host
                      -> Enclosure
                      -> PhaseM LoopState ()
locateHostInEnclosure host enc = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Locating host "
              ++ show host
              ++ " in enclosure "
              ++ show enc

  return $ G.connect enc Has host rg

-- | Record that a node is running on a host.
locateNodeOnHost :: Node
                 -> Host
                 -> PhaseM LoopState ()
locateNodeOnHost node host = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Locating node " ++ (show node) ++ " on host "
              ++ show host

  return $ G.connect host Runs node rg

----------------------------------------------------------
-- Interface related functions                          --
----------------------------------------------------------

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> PhaseM LoopState ()
registerInterface host int = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering interface on host " ++ show host

  let rg' = G.newResource host
        >>> G.newResource int
        >>> G.connect host Has int
          $ rg
  return rg'

----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Find logical devices on a host
findHostStorageDevices :: Host
                       -> PhaseM LoopState [StorageDevice]
findHostStorageDevices host = do
  phaseLog "rg-query" $ "Looking for storage devices on host "
                    ++ show host
  fmap (G.connectedTo host Has) getLocalGraph

-- | Find physical devices in an enclosure
findEnclosureStorageDevices :: Enclosure
                            -> PhaseM LoopState [StorageDevice]
findEnclosureStorageDevices enc = do
  phaseLog "rg-query" $ "Looking for storage devices in enclosure "
                    ++ show enc
  fmap (G.connectedTo enc Has) getLocalGraph

-- | Find additional identifiers for a (physical) storage device.
findStorageDeviceIdentifiers :: StorageDevice
                             -> PhaseM LoopState [DeviceIdentifier]
findStorageDeviceIdentifiers sd = do
  phaseLog "rg-query" $ "Looking for identifiers for physical device "
                    ++ show sd
  fmap (G.connectedTo sd Has) getLocalGraph

-- | Test if a drive have a given identifier
hasStorageDeviceIdentifier :: StorageDevice
                           -> DeviceIdentifier
                           -> PhaseM LoopState Bool
hasStorageDeviceIdentifier ld di = do
  ids <- findStorageDeviceIdentifiers ld
  return $ elem di ids

-- | Add an additional identifier to a logical storage device.
identifyStorageDevice :: StorageDevice
                      -> DeviceIdentifier
                      -> PhaseM LoopState ()
identifyStorageDevice ld di = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Adding identifier "
              ++ show di
              ++ " to device "
              ++ show ld

  let rg' = G.newResource ld
        >>> G.newResource di
        >>> G.connect ld Has di
          $ rg

  return rg'

-- | Register a new drive in the system.
locateStorageDeviceInEnclosure :: Enclosure
                                -> StorageDevice
                                -> PhaseM LoopState ()
locateStorageDeviceInEnclosure enc dev = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " in enclosure "
              ++ show enc

  let rg' = G.newResource enc
        >>> G.newResource dev
        >>> G.connect Cluster Has enc
        >>> G.connect enc Has dev
          $ rg

  return rg'

-- | Register a new drive in the system.
locateStorageDeviceOnHost :: Host
                          -> StorageDevice
                          -> PhaseM LoopState ()
locateStorageDeviceOnHost host dev = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " on host "
              ++ show host

  let rg' = G.newResource host
        >>> G.newResource dev
        >>> G.connect Cluster Has host
        >>> G.connect host Has dev
          $ rg

  return rg'

-- | Merge multiple storage devices into one.
--   Returns the new (merged) device.
mergeStorageDevices :: [StorageDevice]
                    -> PhaseM LoopState StorageDevice
mergeStorageDevices sds = do
  phaseLog "rg" $ "Merging multiple storage devices: "
              ++ (show sds)
  rg <- getLocalGraph
  newUUID <- liftProcess . liftIO $ nextRandom
  let newDisk = StorageDevice newUUID
      rg' = G.mergeResources (\_ -> newDisk) sds
          $ rg
  putLocalGraph rg'
  return newDisk

-- | Get the status of a storage device.
driveStatus :: StorageDevice
            -> PhaseM LoopState (Maybe StorageDeviceStatus)
driveStatus dev = do
  phaseLog "rg-query" $ "Querying status of device " ++ show dev
  rg <- getLocalGraph
  return $ case G.connectedTo dev Is rg of
    [a] -> Just a
    _ -> Nothing

-- | Update the status of a storage device.
updateDriveStatus :: StorageDevice
                  -> String
                  -> PhaseM LoopState ()
updateDriveStatus dev status = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Updating status for device " ++ show dev ++ " to " ++ status
  ds <- driveStatus dev
  phaseLog "rg" $ "Old status was " ++ show ds
  let statusNode = StorageDeviceStatus status
      removeOldNode = case ds of
        Just f -> G.disconnect dev Is f
        Nothing -> id
      rg' = G.newResource statusNode
        >>> G.connect dev Is statusNode
        >>> removeOldNode
          $ rg
  return rg'
