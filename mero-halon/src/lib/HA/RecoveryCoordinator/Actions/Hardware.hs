-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module HA.RecoveryCoordinator.Actions.Hardware
  ( -- * Infrastructure functions
    registerRack
  , registerEnclosure
  , registerBMC
  , findBMCAddress
    -- * Host related functions
  , findHosts
  , findHostEnclosure
  , findNodeHost
  , locateHostInEnclosure
  , locateNodeOnHost
  , registerHost
  , registerOnCluster
  , nodesOnHost
  , hasHostAttr
  , setHostAttr
  , unsetHostAttr
  , findHostsByAttributeFilter
  , findHostsByAttr
  , findHostAttrs
    -- * Cluster status functions
  , setClusterStatus
  , getClusterStatus
    -- * Interface related functions
  , registerInterface
    -- * Drive related functions
    -- ** Searching devices
  , findEnclosureStorageDevices
  , findHostStorageDevices
  , lookupStorageDeviceInEnclosure
  , lookupStorageDeviceOnHost
    -- ** Querying device properties
  , getSDevNode
  , findStorageDeviceIdentifiers
  , hasStorageDeviceIdentifier
  , lookupStorageDevicePaths
  , lookupStorageDeviceSerial
    -- ** Change State
  , identifyStorageDevice
  , updateDriveStatus
  , driveStatus
    --- *** Smart
  , markSMARTTestComplete
  , markSMARTTestIsRunning
  , isStorageDeviceRunningSmartTest
    --- *** Reset
  , markOnGoingReset
  , markResetComplete
  , hasOngoingReset
  , getDiskResetAttempts
  , incrDiskResetAttempts
    --- *** Power
  , markDiskPowerOn
  , markDiskPowerOff
  , isStorageDevicePowered
  , markStorageDeviceRemoved
  , unmarkStorageDeviceRemoved
  , isStorageDriveRemoved
    -- *** Replacement
  , isStorageDeviceReplaced
  , markStorageDeviceReplaced
  , unmarkStorageDeviceReplaced
    -- ** Drive candidates
  , attachStorageDeviceReplacement
  , lookupStorageDeviceReplacement
  , actualizeStorageDeviceReplacement
  , updateStorageDeviceSDev
    -- ** Creating new devices
  , locateStorageDeviceInEnclosure
  , locateStorageDeviceOnHost
  , mergeStorageDevices
) where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Castor
#ifdef USE_MERO
import qualified HA.Resources.Mero as M0
#endif

import Control.Category ((>>>))
import Control.Distributed.Process (liftIO)

import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.UUID.V4 (nextRandom)
import Data.Foldable

import Network.CEP

import Text.Regex.TDFA ((=~))

-- | Register a new rack in the system.
registerRack :: Rack
             -> PhaseM LoopState l ()
registerRack rack = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering rack: "
              ++ show rack

  let rg' = G.newResource rack
        >>> G.connect Cluster Has rack
          $ rg
  return rg'

registerEnclosure :: Rack
                  -> Enclosure
                  -> PhaseM LoopState l ()
registerEnclosure rack enc = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ unwords
                  [ "Registering enclosure", show enc
                  , "in rack", show rack
                  ]
  return  $ G.newResource enc
        >>> G.connect rack Has enc
          $ rg

registerBMC :: Enclosure
            -> BMC
            -> PhaseM LoopState l ()
registerBMC enc bmc = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ unwords
                  [ "Registering BMC", show bmc
                  , "for enclosure", show enc
                  ]

  let rg' = G.newResource bmc
        >>> G.connect enc Has bmc
          $ rg
  return rg'

-- | Find the IP address of the BMC corresponding to this host.
findBMCAddress :: Host
               -> PhaseM LoopState l (Maybe String)
findBMCAddress host = do
    phaseLog "rg-query" $ "Getting BMC address for host " ++ show host
    g <- getLocalGraph
    return . listToMaybe $
      [ bmc_addr bmc
      | (enc :: Enclosure) <- G.connectedFrom Has host g
      , bmc <- G.connectedTo enc Has g
      ]

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
registerHost host = registerOnCluster host $ "Registering host: " ++ show host

-- | Register a new thing on 'Cluster' as long as it has a 'Has'
-- 'G.Relation' instance.
registerOnCluster :: G.Relation Has Cluster a
                  => a -- ^ The thing to register
                  -> String -- ^ The message to log
                  -> PhaseM LoopState l ()
registerOnCluster x m = modifyLocalGraph $ \rg -> do
  phaseLog "rg" m
  let rg' = G.newResource x
        >>> G.connect Cluster Has x
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
-- Host attribute functions                             --
----------------------------------------------------------

-- | Test if a host has the specified attribute.
hasHostAttr :: HostAttr
            -> Host
            -> PhaseM LoopState l Bool
hasHostAttr f h = do
  phaseLog "rg-query" $ "Checking host "
                      ++ show h
                      ++ " for attribute "
                      ++ show f
  g <- getLocalGraph
  return $ G.isConnected h Has f g

-- | Set an attribute on a host. Note that this will not replace
--   any existing attributes - that must be done manually.
setHostAttr :: Host
            -> HostAttr
            -> PhaseM LoopState l ()
setHostAttr h f = do
  phaseLog "rg" $ unwords [ "Setting attribute", show f
                , "on host", show h ]
  modifyLocalGraph
      $ return
      . (G.newResource f
    >>> G.connect h Has f)

unsetHostAttr :: Host
              -> HostAttr
              -> PhaseM LoopState l ()
unsetHostAttr h f = do
  phaseLog "rg" $ unwords [ "Unsetting attribute", show f
                          , "on host", show h ]
  modifyLocalGraph
    $ return
    . G.disconnect h Has f

-- | Find hosts with attributes satisfying the user supplied predicate
findHostsByAttributeFilter :: String -- ^ Message to log
                           -> ([HostAttr] -> Bool) -- ^ Filter predicate
                           -> PhaseM LoopState l [Host]
findHostsByAttributeFilter msg p = do
  phaseLog "rg-query" msg
  g <- getLocalGraph
  return $ [ host | host@(Host {}) <- G.connectedTo Cluster Has g
                  , p (G.connectedTo host Has g) ]

-- | A specialised version of 'findHostsByAttributeFilter' that returns all
-- hosts labelled with at least the given attribute.
findHostsByAttr :: HostAttr
                -> PhaseM LoopState l [Host]
findHostsByAttr label =
    findHostsByAttributeFilter ( "Looking for hosts with attribute "
                                ++ show label) p
  where
    p = elem label

-- | Find all attributes possessed by the given host.
findHostAttrs :: Host
              -> PhaseM LoopState l [HostAttr]
findHostAttrs host = do
  phaseLog "rg-query" $ "Getting attributes for host " ++ show host
  g <- getLocalGraph
  return $ G.connectedTo host Has g


----------------------------------------------------------
-- Cluster status functions                             --
----------------------------------------------------------

-- | Obtain the current 'ClusterStatus' of the 'Cluster'. If the
-- status has not been set, it is assumed to be 'ONLINE'.
getClusterStatus :: PhaseM LoopState l ClusterStatus
getClusterStatus = do
  phaseLog "rg-query" "Looking up cluster status"
  getLocalGraph >>= \g ->
    return . fromMaybe ONLINE . listToMaybe $ G.connectedTo Cluster Has g

-- | Set the 'ClusterStatus' for a 'Cluster'. Any other status that
-- has been previously set is overwritten.
setClusterStatus :: ClusterStatus -> PhaseM LoopState l ()
setClusterStatus cs = do
  phaseLog "rg" $ "Setting cluster status to " ++ show cs
  modifyLocalGraph $ \g -> do
    return $ G.newResource cs >>> G.connectUnique Cluster Has cs $ g

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

isStorageDriveRemoved :: StorageDevice -> PhaseM LoopState l Bool
isStorageDriveRemoved sd = do
  rg <- getLocalGraph
  return $ not . null $ [ () | SDRemovedAt{} <- G.connectedTo sd Has rg ]

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

-- | Lookup filesystem paths for storage devices (e.g. /dev/sda1)
lookupStorageDevicePaths :: StorageDevice -> PhaseM LoopState l [String]
lookupStorageDevicePaths sd =
    mapMaybe extractPath <$> findStorageDeviceIdentifiers sd
  where
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | Lookup serial number of the storage device
lookupStorageDeviceSerial :: StorageDevice -> PhaseM LoopState l [String]
lookupStorageDeviceSerial sd =
    mapMaybe extractSerial <$> findStorageDeviceIdentifiers sd
  where
    extractSerial (DISerialNumber x) = Just x
    extractSerial _ = Nothing

-- | Lookup a storage device in given enclosure at given position.
lookupStorageDeviceInEnclosure :: Enclosure
                               -> DeviceIdentifier
                               -> PhaseM LoopState l (Maybe StorageDevice)
lookupStorageDeviceInEnclosure enc ident = do
    rg <- getLocalGraph
    return $ listToMaybe
           [ device
           | device <- G.connectedTo  enc  Has rg :: [StorageDevice]
           , G.isConnected device Has ident rg :: Bool
           ]

lookupStorageDeviceOnHost :: Host
                          -> DeviceIdentifier
                          -> PhaseM LoopState l (Maybe StorageDevice)
lookupStorageDeviceOnHost host ident = do
    rg <- getLocalGraph
    return $ listToMaybe
           [ device
           | device <- G.connectedTo  host Has rg :: [StorageDevice]
           , G.isConnected device Has ident rg :: Bool
           ]

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
  let menc = listToMaybe (G.connectedFrom Has host rg :: [Enclosure])
  phaseLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " on host "
              ++ show host
              ++ (case menc of
                    Nothing -> ""
                    Just e  -> " (" ++ show e ++ ")")

  let rg' = G.newResource host
        >>> G.newResource dev
        >>> G.connect Cluster Has host
        >>> G.connect host Has dev
        $ case menc of
            Nothing -> rg
            Just e  -> G.connect e Has dev rg

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
                  -> String -- ^ Status.
                  -> String -- ^ Reason.
                  -> PhaseM LoopState l ()
updateDriveStatus dev status reason = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Updating status for device " ++ show dev ++ " to " ++ status ++ "("++reason++")"
  ds <- driveStatus dev
  phaseLog "rg" $ "Old status was " ++ show ds
  let statusNode = StorageDeviceStatus status reason
      removeOldNode = case ds of
        Just f -> G.disconnect dev Is f
        Nothing -> id
      rg' = G.newResource statusNode
        >>> G.connect dev Is statusNode
        >>> removeOldNode
          $ rg
  return rg'

updateStorageDeviceSDev :: StorageDevice -> PhaseM LoopState l ()
updateStorageDeviceSDev sdev = do
  phaseLog "rg" $ "updating SDev that belongs to " ++ show sdev
  modifyGraph $ rgUpdateStorageDeviceSDev sdev 

-- | Update mero device that correspong to storage device, by setting correct
-- path to that.
rgUpdateStorageDeviceSDev :: StorageDevice -> G.Graph -> G.Graph
#ifdef USE_MERO
rgUpdateStorageDeviceSDev sdev rg =
   let mdev =  do
         (disk :: M0.Disk) <- listToMaybe $ G.connectedFrom M0.At sdev rg
         (dev  :: M0.SDev) <- listToMaybe $ G.connectedFrom M0.IsOnHardware disk rg
         path <- listToMaybe $ [p | (DIPath p) <- G.connectedTo sdev Has rg]
         return (dev{M0.d_path = path}, dev)
   in maybe rg (\(new, dev) -> G.mergeResources (const new) [dev] rg) mdev
#else
rgUpdateStorageDeviceSDev _ rg = rg
#endif

-- | Replace storage device node with its new version.
actualizeStorageDeviceReplacement :: StorageDevice -> PhaseM LoopState l ()
actualizeStorageDeviceReplacement sdev = do
    phaseLog "rg" "Set disk candidate as an active disk"
    modifyLocalGraph $ \rg ->
      case listToMaybe $ G.connectedFrom ReplacedBy sdev rg of
        Nothing -> do
          phaseLog "rg" "failed to find disk that was attached"
          return rg
        Just dev -> do
          let rg' = G.mergeResources (const dev) [sdev]
                >>> G.disconnect sdev ReplacedBy dev
                >>> G.disconnect sdev Has SDRemovedAt
                >>> rgUpdateStorageDeviceSDev sdev
                  $ rg
          return rg'

-- | Attach new version of 'StorageDevice'
attachStorageDeviceReplacement :: StorageDevice -> [DeviceIdentifier] -> PhaseM LoopState l StorageDevice
attachStorageDeviceReplacement dev dis = do
  phaseLog "rg" $ "Inserting new device candidate to " ++ show dev
  uuid <- liftProcess . liftIO $ nextRandom
  let newDev = StorageDevice uuid
  forM_ dis $ identifyStorageDevice newDev
  modifyLocalGraph $ return . G.connect dev ReplacedBy newDev
  return newDev

-- | Find if storage device has replacement and return new drive if this is a case.
lookupStorageDeviceReplacement :: StorageDevice -> PhaseM LoopState l (Maybe StorageDevice)
lookupStorageDeviceReplacement sdev = do
    gr <- getLocalGraph
    return $ listToMaybe $ G.connectedTo sdev ReplacedBy gr

-- | Set an attribute on a storage device.
setStorageDeviceAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM LoopState l ()
setStorageDeviceAttr sd attr  = do
    phaseLog "rg" $ "Setting disk attribute " ++ show attr ++ " on " ++ show sd
    modifyGraph (G.newResource attr >>> G.connect sd Has attr)

-- | Unset an attribute on a storage device.
unsetStorageDeviceAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM LoopState l ()
unsetStorageDeviceAttr sd attr = do
    phaseLog "rg" $ "Unsetting disk attribute "
                  ++ show attr ++ " on " ++ show sd
    modifyGraph (G.disconnect sd Has attr)

-- | Find (an) attribute matching the given filter on a storage device.
findStorageDeviceAttr :: (StorageDeviceAttr -> Bool)
                      -> StorageDevice
                      -> PhaseM LoopState l (Maybe StorageDeviceAttr)
findStorageDeviceAttr k sdev = do
    rg <- getLocalGraph
    let attrs =
          [ attr | attr <- G.connectedTo sdev Has rg :: [StorageDeviceAttr]
                 , k attr
                 ]
    return $ listToMaybe attrs

-- | Test whether a given device is currently undergoing a reset operation.
hasOngoingReset :: StorageDevice -> PhaseM LoopState l Bool
hasOngoingReset =
    fmap (maybe False (const True)) . findStorageDeviceAttr go
  where
    go SDOnGoingReset = True
    go _              = False

-- | Mark that a storage device is undergoing reset.
markOnGoingReset :: StorageDevice -> PhaseM LoopState l ()
markOnGoingReset sdev = do
    let _F SDOnGoingReset = True
        _F _                 = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing -> setStorageDeviceAttr sdev SDOnGoingReset
      _       -> return ()

-- | Mark that a storage device has completed reset.
markResetComplete :: StorageDevice -> PhaseM LoopState l ()
markResetComplete sdev = do
    let _F SDOnGoingReset = True
        _F _                 = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing  -> return ()
      Just old -> unsetStorageDeviceAttr sdev old

incrDiskResetAttempts :: StorageDevice -> PhaseM LoopState l ()
incrDiskResetAttempts sdev = do
    let _F (SDResetAttempts _) = True
        _F _                        = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Just old@(SDResetAttempts i) -> do
        unsetStorageDeviceAttr sdev old
        setStorageDeviceAttr sdev (SDResetAttempts (i+1))
      _ -> setStorageDeviceAttr sdev (SDResetAttempts 1)

isStorageDevicePowered :: StorageDevice -> PhaseM LoopState l Bool
isStorageDevicePowered sdev = do
    phaseLog "rg" $ "Checking power status for storage device: " ++ show sdev
    fmap (maybe False (const True)) . findStorageDeviceAttr go $ sdev
  where
    go SDPowered = True
    go _         = False

markStorageDeviceRemoved :: StorageDevice -> PhaseM LoopState l ()
markStorageDeviceRemoved sdev = do
    let _F SDRemovedAt = True
        _F _           = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing -> setStorageDeviceAttr sdev SDRemovedAt
      _       -> return ()

unmarkStorageDeviceRemoved :: StorageDevice -> PhaseM LoopState l ()
unmarkStorageDeviceRemoved sdev = do
    let _F SDRemovedAt = True
        _F _           = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing  -> return ()
      Just old -> unsetStorageDeviceAttr sdev old

markDiskPowerOn :: StorageDevice -> PhaseM LoopState l ()
markDiskPowerOn sdev = do
  let _F SDPowered = True
      _F _         = False
  m <- findStorageDeviceAttr _F sdev
  case m of
    Nothing -> setStorageDeviceAttr sdev SDPowered
    _       -> return ()

markDiskPowerOff :: StorageDevice -> PhaseM LoopState l ()
markDiskPowerOff sdev = do
  let _F SDPowered = True
      _F _              = False
  m <- findStorageDeviceAttr _F sdev
  case m of
    Nothing  -> return ()
    Just old -> unsetStorageDeviceAttr sdev old

isStorageDeviceRunningSmartTest :: StorageDevice -> PhaseM LoopState l Bool
isStorageDeviceRunningSmartTest sdev = do
    phaseLog "rg"
          $ "Checking SMART test status for storage device: " ++ show sdev
    fmap (maybe False (const True)) . findStorageDeviceAttr go $ sdev
  where
    go SDSMARTRunning = True
    go _              = False

markSMARTTestIsRunning :: StorageDevice -> PhaseM LoopState l ()
markSMARTTestIsRunning sdev = do
  let _F SDSMARTRunning = True
      _F _              = False
  m <- findStorageDeviceAttr _F sdev
  case m of
    Nothing -> setStorageDeviceAttr sdev SDSMARTRunning
    _       -> return ()

markSMARTTestComplete :: StorageDevice -> PhaseM LoopState l ()
markSMARTTestComplete sdev = do
  let _F SDSMARTRunning = True
      _F _              = False
  m <- findStorageDeviceAttr _F sdev
  case m of
    Nothing  -> return ()
    Just old -> unsetStorageDeviceAttr sdev old

getDiskResetAttempts :: StorageDevice -> PhaseM LoopState l Int
getDiskResetAttempts sdev = do
  let _F (SDResetAttempts _) = True
      _F _                   = False
  m <- findStorageDeviceAttr _F sdev
  case m of
    Just (SDResetAttempts i) -> return i
    _                        -> return 0

getSDevNode :: StorageDevice -> PhaseM LoopState l [Node]
getSDevNode sdev = do
  rg <- getLocalGraph
  let nds = [ node | encl <- G.connectedFrom Has sdev rg :: [Enclosure]
                   , host <- G.connectedTo encl Has rg :: [Host]
                   , node <- G.connectedTo host Runs rg :: [Node]
            ]
  return nds

markStorageDeviceReplaced :: StorageDevice -> PhaseM LoopState l ()
markStorageDeviceReplaced sdev = do
  let _F SDReplaced = True
      _F _          = False
  m <- findStorageDeviceAttr _F sdev
  case m of
    Nothing -> setStorageDeviceAttr sdev SDReplaced
    _       -> return ()

unmarkStorageDeviceReplaced :: StorageDevice -> PhaseM LoopState l ()
unmarkStorageDeviceReplaced sdev = do
  let _F SDReplaced = True
      _F _          = False
  m <- findStorageDeviceAttr _F sdev
  case m of
    Nothing  -> return ()
    Just old -> unsetStorageDeviceAttr sdev old

isStorageDeviceReplaced :: StorageDevice -> PhaseM LoopState l Bool
isStorageDeviceReplaced sdev = do
    phaseLog "rg"
          $ "Checking Replaced status for storage device: " ++ show sdev
    fmap (maybe False (const True)) . findStorageDeviceAttr go $ sdev
  where
    go SDReplaced = True
    go _          = False
