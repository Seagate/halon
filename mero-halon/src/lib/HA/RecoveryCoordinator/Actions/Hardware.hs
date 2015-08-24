-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}

module HA.RecoveryCoordinator.Actions.Hardware
  ( -- * Host related functions
    findHosts
  , findHostEnclosure
  , findHostLabels
  , findHostsLabelled
  , findHostsLabelledBy
  , findNodeHost
  , hasHostStatusFlag
  , setHostStatusFlag
  , unsetHostStatusFlag
  , hasLabel
  , labelHost
  , locateHostInEnclosure
  , locateNodeOnHost
  , registerHost
  , nodesOnHost
    -- * Interface related functions
  , registerInterface
  , findBMCAddress
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

import Data.List (foldl')
import Data.Maybe (listToMaybe)
import Data.UUID.V4 (nextRandom)

import Network.CEP

import Text.Regex.TDFA ((=~))

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find the host running the given node
findNodeHost :: Node
             -> PhaseM LoopState l (Maybe Host)
findNodeHost node =  do
  phaseLog "rg-query" $ "Looking for host running " ++ show node
  g <- getLocalGraph
  return $ case G.connectedFrom Runs node g of
    [h] -> Just h
    _ -> Nothing

-- | Find the enclosure containing the given host.
findHostEnclosure :: Host
                  -> PhaseM LoopState l (Maybe Enclosure)
findHostEnclosure host = do
  phaseLog "rg-query" $ "Looking for enclosure containing " ++ show host
  g <- getLocalGraph
  return $ case G.connectedFrom Has host g of
    [h] -> Just h
    _ -> Nothing

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String
          -> PhaseM LoopState l [Host]
findHosts regex = do
  phaseLog "rg-query" $ "Looking for hosts matching regex " ++ regex
  g <- getLocalGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> PhaseM LoopState l [Node]
nodesOnHost host = do
  phaseLog "rg-query" $ "Looking for nodes on host " ++ show host
  fmap (G.connectedTo host Runs) getLocalGraph

-- | Register a new host in the system.
registerHost :: Host
             -> PhaseM LoopState l ()
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
                      -> PhaseM LoopState l ()
locateHostInEnclosure host enc = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Locating host "
              ++ show host
              ++ " in enclosure "
              ++ show enc

  return $ G.connect enc Has host rg

-- | Record that a node is running on a host.
locateNodeOnHost :: Node
                 -> Host
                 -> PhaseM LoopState l ()
locateNodeOnHost node host = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Locating node " ++ (show node) ++ " on host "
              ++ show host

  return $ G.connect host Runs node rg

----------------------------------------------------------
-- Host status functions                                --
----------------------------------------------------------

hasHostStatusFlag :: HostStatusFlag
                  -> Host
                  -> PhaseM LoopState l Bool
hasHostStatusFlag f h = do
  phaseLog "rg-query" $ "Checking host "
                      ++ show h
                      ++ " for status "
                      ++ show f
  g <- getLocalGraph
  return $ case G.connectedTo h Is g of
    [] -> False
    statuses -> hasStatusFlag f $ mconcat statuses

modifyHostStatus :: Host
                 -> String -- ^ Message describing the modification
                 -> (HostStatus -> HostStatus)
                 -> PhaseM LoopState l ()
modifyHostStatus h msg f = modifyLocalGraph $ \rg -> do
  phaseLog "rg" msg
  return $ case G.connectedTo h Is rg of
    [] -> let
        status = f mempty
      in
        G.newResource status
        >>> G.connect h Is status
          $ rg
    xs -> let
        status = f $ mconcat xs
        removeOldStatus = foldl' (.) id . fmap (G.disconnect h Is) $ xs
      in
        G.newResource status
        >>> removeOldStatus
        >>> G.connect h Is status
          $ rg

setHostStatusFlag :: Host
                  -> HostStatusFlag
                  -> PhaseM LoopState l ()
setHostStatusFlag h f = let
    msg = unwords [ "Setting flag", show f
                  , "on host", show h ]
  in modifyHostStatus h msg (setStatusFlag f)

unsetHostStatusFlag :: Host
                    -> HostStatusFlag
                    -> PhaseM LoopState l ()
unsetHostStatusFlag h f = let
    msg = unwords [ "Unsetting flag", show f
                  , "on host", show h ]
  in modifyHostStatus h msg (unsetStatusFlag f)

----------------------------------------------------------
-- Host label functions                                 --
----------------------------------------------------------

-- | Find hosts with labels satisfying the user supplied predicate
findHostsLabelledBy :: String -- ^ Message to log
                    -> ([Label] -> Bool) -- ^ Filter predicate
                    -> PhaseM LoopState l [Host]
findHostsLabelledBy msg p = do
  phaseLog "rg-query" msg
  g <- getLocalGraph
  return $ [ host | host@(Host {}) <- G.connectedTo Cluster Has g
                  , p (G.connectedTo host Has g) ]

-- | A specialised version of 'findHostsLabelledBy' that returns all
-- hosts labelled with at least the given label.
findHostsLabelled :: Label
                  -> PhaseM LoopState l [Host]
findHostsLabelled label =
  findHostsLabelledBy ("Looking for hosts with label " ++ show label) p
  where
    p = elem label

-- | Attach a label to the given host.
labelHost :: Host
          -> Label
          -> PhaseM LoopState l ()
labelHost host label = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ unwords [ "Adding label", show label
                          , "to host", show host ]
  let rg' = G.newResource host
        >>> G.newResource label
        >>> G.connect host Has label
          $ rg

  return rg'

hasLabel :: Host
         -> Label
         -> PhaseM LoopState l Bool
hasLabel host label = do
  phaseLog "rg-query" $ unwords [ "Checking if host", show host
                                , "has label", show label ]
  g <- getLocalGraph
  return $ label `elem` G.connectedTo host Has g

findHostLabels :: Host
               -> PhaseM LoopState l [Label]
findHostLabels host = do
  phaseLog "rg-query" $ "Getting labels for" ++ show host
  g <- getLocalGraph
  return $ G.connectedTo host Has g

----------------------------------------------------------
-- Interface related functions                          --
----------------------------------------------------------

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> PhaseM LoopState l ()
registerInterface host int = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering interface on host " ++ show host

  let rg' = G.newResource host
        >>> G.newResource int
        >>> G.connect host Has int
          $ rg
  return rg'

-- | XXX Todo make this identify the address correctly.
findBMCAddress :: Host
               -> PhaseM LoopState l (Maybe String)
findBMCAddress host = do
    phaseLog "rg-query" $ "Getting BMC address for host " ++ show host
    g <- getLocalGraph
    return . listToMaybe . fmap unIf $ G.connectedTo host Has g
  where
    unIf (Interface a) = a


----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Find logical devices on a host
findHostStorageDevices :: Host
                       -> PhaseM LoopState l [StorageDevice]
findHostStorageDevices host = do
  phaseLog "rg-query" $ "Looking for storage devices on host "
                    ++ show host
  fmap (G.connectedTo host Has) getLocalGraph

-- | Find physical devices in an enclosure
findEnclosureStorageDevices :: Enclosure
                            -> PhaseM LoopState l [StorageDevice]
findEnclosureStorageDevices enc = do
  phaseLog "rg-query" $ "Looking for storage devices in enclosure "
                    ++ show enc
  fmap (G.connectedTo enc Has) getLocalGraph

-- | Find additional identifiers for a (physical) storage device.
findStorageDeviceIdentifiers :: StorageDevice
                             -> PhaseM LoopState l [DeviceIdentifier]
findStorageDeviceIdentifiers sd = do
  phaseLog "rg-query" $ "Looking for identifiers for physical device "
                    ++ show sd
  fmap (G.connectedTo sd Has) getLocalGraph

-- | Test if a drive have a given identifier
hasStorageDeviceIdentifier :: StorageDevice
                           -> DeviceIdentifier
                           -> PhaseM LoopState l Bool
hasStorageDeviceIdentifier ld di = do
  ids <- findStorageDeviceIdentifiers ld
  return $ elem di ids

-- | Add an additional identifier to a logical storage device.
identifyStorageDevice :: StorageDevice
                      -> DeviceIdentifier
                      -> PhaseM LoopState l ()
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
                                -> PhaseM LoopState l ()
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
                          -> PhaseM LoopState l ()
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
                    -> PhaseM LoopState l StorageDevice
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
            -> PhaseM LoopState l (Maybe StorageDeviceStatus)
driveStatus dev = do
  phaseLog "rg-query" $ "Querying status of device " ++ show dev
  rg <- getLocalGraph
  return $ case G.connectedTo dev Is rg of
    [a] -> Just a
    _ -> Nothing

-- | Update the status of a storage device.
updateDriveStatus :: StorageDevice
                  -> String
                  -> PhaseM LoopState l ()
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
