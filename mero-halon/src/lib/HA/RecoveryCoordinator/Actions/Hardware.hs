-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}

module HA.RecoveryCoordinator.Actions.Hardware
  ( -- * Host related functions
    locateNodeOnHost
  , registerHost
  , nodesOnHost
  , findHosts
    -- * Interface related functions
  , registerInterface
    -- * Drive related functions
  , driveStatus
  , registerDrive
  , updateDriveStatus
) where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Mero

import Control.Category ((>>>))
import qualified Control.Monad.State.Strict as State

import Network.CEP

import Text.Regex.TDFA ((=~))

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String
          -> CEP LoopState [Host]
findHosts regex = do
  cepLog "rg-query" $ "Looking for hosts matching regex " ++ regex
  g <- State.gets lsGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> CEP LoopState [Node]
nodesOnHost host = do
  cepLog "rg-query" $ "Looking for nodes on host " ++ show host
  State.gets $ G.connectedTo host Runs . lsGraph

-- | Register a new host in the system.
registerHost :: Host
             -> CEP LoopState ()
registerHost host = do
  cepLog "rg" $ "Registering host: "
              ++ show host
  ls <- State.get
  let rg' = G.newResource host
        >>> G.connect Cluster Has host
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Record that a node is running on a host.
locateNodeOnHost :: Node
                 -> Host
                 -> CEP LoopState ()
locateNodeOnHost node host = do
  cepLog "rg" $ "Locating node " ++ (show node) ++ " on host "
              ++ show host
  ls <- State.get
  let rg' = G.connect host Runs node
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

----------------------------------------------------------
-- Interface related functions                          --
----------------------------------------------------------

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> CEP LoopState ()
registerInterface host int = do
  cepLog "rg" $ "Registering interface on host " ++ show host
  ls <- State.get
  let rg' = G.newResource host
        >>> G.newResource int
        >>> G.connect host Has int
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Register a new drive in the system.
registerDrive :: Enclosure
              -> StorageDevice
              -> CEP LoopState ()
registerDrive enc dev = do
  cepLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " in enclosure "
              ++ show enc
  ls <- State.get
  let rg' = G.newResource enc
        >>> G.newResource dev
        >>> G.connect Cluster Has enc
        >>> G.connect enc Has dev
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Get the status of a storage device.
driveStatus :: StorageDevice
            -> CEP LoopState (Maybe StorageDeviceStatus)
driveStatus dev = do
  cepLog "rg-query" $ "Querying status of device " ++ show dev
  ls <- State.get
  return $ case G.connectedTo dev Is (lsGraph ls) of
    [a] -> Just a
    _ -> Nothing

-- | Update the status of a storage device.
updateDriveStatus :: StorageDevice
                  -> String
                  -> CEP LoopState ()
updateDriveStatus dev status = do
  cepLog "rg" $ "Updating status for device " ++ show dev ++ " to " ++ status
  ls <- State.get
  ds <- driveStatus dev
  cepLog "rg" $ "Old status was " ++ show ds
  let statusNode = StorageDeviceStatus status
      removeOldNode = case ds of
        Just f -> G.disconnect dev Is f
        Nothing -> id
      rg' = G.newResource statusNode
        >>> G.connect dev Is statusNode
        >>> removeOldNode
          $ lsGraph ls
  State.put ls { lsGraph = rg' }
