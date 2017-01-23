{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Actions on hardware entities.
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
    -- * Interface related functions
  , registerInterface
    -- * Drive related functions
    -- ** Searching devices
  , findEnclosureStorageDevices
  , findHostStorageDevices
  , lookupEnclosureOfStorageDevice
  , lookupStorageDeviceInEnclosure
  , lookupStorageDeviceOnHost
  , lookupStorageDevicesWithDI
  , lookupStorageDevicesWithAttr
    -- ** Querying device properties
  , getSDevNode
  , getSDevHost
    -- ** Device attributes
  , findStorageDeviceAttrs
  , setStorageDeviceAttr
  , unsetStorageDeviceAttr
    --- *** Reset
  , markOnGoingReset
  , markResetComplete
  , hasOngoingReset
  , getDiskResetAttempts
  , incrDiskResetAttempts
    --- *** Power
  , isStorageDriveRemoved
    -- ** Creating new devices
  , locateStorageDeviceInEnclosure
) where

import           Data.Maybe (listToMaybe, maybeToList)
import qualified Data.Set as Set
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.RC.Actions.Log (actLog)
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Services.Ekg.RC
import           Network.CEP
import           Text.Regex.TDFA ((=~))

-- | Register a new rack in the system.
registerRack :: Rack
             -> PhaseM RC l ()
registerRack rack = do
  actLog "registerRack" [("rack", show rack)]
  modifyGraph $ G.connect Cluster Has rack

-- | 'G.connect' the given 'Enclosure' to the 'Rack'.
registerEnclosure :: Rack
                  -> Enclosure
                  -> PhaseM RC l ()
registerEnclosure rack enc = do
  actLog "registerEnclosure" [("rack", show rack), ("enclosure", show enc)]
  modifyGraph $ G.connect rack Has enc

-- | 'G.connect' the givne 'BMC' to the 'Enclosure'.
registerBMC :: Enclosure
            -> BMC
            -> PhaseM RC l ()
registerBMC enc bmc = do
  actLog "registerBMC" [("bmc", show bmc), ("enclosure", show enc)]
  modifyGraph $ G.connect enc Has bmc

-- | Find the IP address of the BMC corresponding to this host.
findBMCAddress :: Host
               -> PhaseM RC l (Maybe String)
findBMCAddress host = do
    g <- getLocalGraph
    return . listToMaybe $
      [ bmc_addr bmc
      | Just (enc :: Enclosure) <- [G.connectedFrom Has host g]
      , bmc <- G.connectedTo enc Has g
      ]

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find the host running the given node
findNodeHost :: Node
             -> PhaseM RC l (Maybe Host)
findNodeHost node = G.connectedFrom Runs node <$> getLocalGraph

-- | Find the enclosure containing the given host.
findHostEnclosure :: Host
                  -> PhaseM RC l (Maybe Enclosure)
findHostEnclosure host =
    G.connectedFrom Has host <$> getLocalGraph

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String
          -> PhaseM RC l [Host]
findHosts regex = do
  g <- getLocalGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> PhaseM RC l [Node]
nodesOnHost host = do
  fmap (G.connectedTo host Runs) getLocalGraph

-- | Register a new host in the system.
registerHost :: Host
             -> PhaseM RC l ()
registerHost host = registerOnCluster host $ "Registering host on cluster: " ++ show host

-- | Register a new thing on 'Cluster' as long as it has a 'Has'
-- 'G.Relation' instance. Does nothing if the resource is already
-- connected.
registerOnCluster :: G.Relation Has Cluster a
                  => a -- ^ The thing to register
                  -> String -- ^ The message to log
                  -> PhaseM RC l ()
registerOnCluster x m = modifyLocalGraph $ \rg ->
  if G.isConnected Cluster Has x rg
  then return rg
  else do
    phaseLog "rg" m
    return $! G.connect Cluster Has x rg

-- | Record that a host is running in an enclosure.
locateHostInEnclosure :: Host
                      -> Enclosure
                      -> PhaseM RC l ()
locateHostInEnclosure host enc = do
  actLog "locateHostInEnclosure" [("host", show host), ("enclosure", show enc)]
  modifyGraph $ G.connect enc Has host

-- | Record that a node is running on a host. Does not re-connect if
-- the 'Node' is already connected to the given 'Host'.
locateNodeOnHost :: Node
                 -> Host
                 -> PhaseM RC l ()
locateNodeOnHost node host = modifyLocalGraph $ \rg ->
  if G.isConnected host Runs node rg
  then return rg
  else do
    actLog "locateHostInEnclosure" [("host", show host), ("node", show node)]
    return $ G.connect host Runs node rg

----------------------------------------------------------
-- Host attribute functions                             --
----------------------------------------------------------

-- | Test if a host has the specified attribute.
hasHostAttr :: HostAttr
            -> Host
            -> PhaseM RC l Bool
hasHostAttr f h = do
  g <- getLocalGraph
  return $ G.isConnected h Has f g

-- | Set an attribute on a host. Note that this will not replace
--   any existing attributes - that must be done manually.
setHostAttr :: Host
            -> HostAttr
            -> PhaseM RC l ()
setHostAttr h f = do
  actLog "setHostAttr" [("host", show h), ("attr", show f)]
  modifyGraph $ G.connect h Has f

-- | Remove the given 'HostAttr' from the 'Host'.
unsetHostAttr :: Host
              -> HostAttr
              -> PhaseM RC l ()
unsetHostAttr h f = do
  actLog "unsetHostAttr" [("host", show h), ("attr", show f)]
  modifyGraph $ G.disconnect h Has f

-- | Find hosts with attributes satisfying the user supplied predicate
findHostsByAttributeFilter :: String -- ^ Message to log
                           -> ([HostAttr] -> Bool) -- ^ Filter predicate
                           -> PhaseM RC l [Host]
findHostsByAttributeFilter msg p = do
  phaseLog "rg-query" msg
  g <- getLocalGraph
  return $ [ host | host@(Host {}) <- G.connectedTo Cluster Has g
                  , p (G.connectedTo host Has g) ]

-- | A specialised version of 'findHostsByAttributeFilter' that returns all
-- hosts labelled with at least the given attribute.
findHostsByAttr :: HostAttr
                -> PhaseM RC l [Host]
findHostsByAttr label =
    findHostsByAttributeFilter ( "Looking for hosts with attribute "
                                ++ show label) p
  where
    p = elem label

-- | Find all attributes possessed by the given host.
findHostAttrs :: Host
              -> PhaseM RC l [HostAttr]
findHostAttrs host = do
  G.connectedTo host Has <$> getLocalGraph

----------------------------------------------------------
-- Interface related functions                          --
----------------------------------------------------------

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> PhaseM RC l ()
registerInterface host int = do
  actLog "registerInterface" [("host", show host), ("int", show int)]
  modifyGraph $ G.connect host Has int

----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Find logical devices on a host
findHostStorageDevices :: Host
                       -> PhaseM RC l [StorageDevice]
findHostStorageDevices host = flip fmap getLocalGraph $ \rg -> Set.toList $
  Set.fromList [sdev  | enc  :: Enclosure <- maybeToList $ G.connectedFrom Has host rg
               , loc  :: Slot <- G.connectedTo enc Has rg
               , sdev :: StorageDevice <- maybeToList $ G.connectedFrom Has loc rg ]
  `Set.union` fallback rg
  where
    fallback rg = Set.fromList
      [ sdev | enc  :: Enclosure <- maybeToList $ G.connectedFrom Has host rg
      , sdev :: StorageDevice <- G.connectedTo enc Has rg
      ]

-- | Find physical devices in an enclosure
findEnclosureStorageDevices :: Enclosure
                            -> PhaseM RC l [StorageDevice]
findEnclosureStorageDevices enc = do
  fmap (G.connectedTo enc Has) getLocalGraph

isStorageDriveRemoved :: StorageDevice -> PhaseM RC l Bool
isStorageDriveRemoved sd = do
  rg <- getLocalGraph
  return $ (||) (maybe True (\Slot{} -> False)
                  $ G.connectedTo sd Has rg)
                (maybe True (\Enclosure{} -> False)
                  $ G.connectedFrom Has sd rg)

-- | Lookup a storage device in given enclosure at given position.
lookupStorageDeviceInEnclosure :: Enclosure
                               -> DeviceIdentifier
                               -> PhaseM RC l (Maybe StorageDevice)
lookupStorageDeviceInEnclosure enc ident = do
    rg <- getLocalGraph
    return $ listToMaybe
          [ device
          | device <- G.connectedTo enc Has rg :: [StorageDevice]
          , G.isConnected device Has ident rg :: Bool
          ]

-- | Find all 'StorageDevice's with the given 'DeviceIdentifier'.
lookupStorageDevicesWithDI :: DeviceIdentifier -> PhaseM RC l [StorageDevice]
lookupStorageDevicesWithDI di = G.connectedFrom Has di <$> getLocalGraph

-- | Find all 'StorageDevice's with the given 'StorageDeviceAttr'.
lookupStorageDevicesWithAttr :: StorageDeviceAttr -> PhaseM RC l [StorageDevice]
lookupStorageDevicesWithAttr attr = G.connectedFrom Has attr <$> getLocalGraph

-- | Lookup 'StorageDevice' on a host if it was not found to a lookup
-- on enclosure that host is on.
lookupStorageDeviceOnHost :: Host
                          -> DeviceIdentifier
                          -> PhaseM RC l (Maybe StorageDevice)
lookupStorageDeviceOnHost host ident = do
      rg <- getLocalGraph
      case G.connectedFrom Has host rg of
        Nothing -> return Nothing
        Just enc -> lookupStorageDeviceInEnclosure enc ident

-- | Given a 'DeviceIdentifier', try to find the 'Enclosure' that the
-- device with the identifier belongs to. Useful when SSPL is unable
-- to tell us the enclosure of the device but we may have that info
-- already.
lookupEnclosureOfStorageDevice :: StorageDevice
                               -> PhaseM RC l (Maybe Enclosure)
lookupEnclosureOfStorageDevice sd =
    G.connectedFrom Has sd <$> getLocalGraph

-- | Register a new drive in the system.
locateStorageDeviceInEnclosure :: Enclosure
                                -> StorageDevice
                                -> PhaseM RC l ()
locateStorageDeviceInEnclosure enc dev = do
  actLog "locateStorageDeviceInEnclosure"
          [("device", show dev), ("enclosure", show enc)]
  modifyGraph $ G.connect enc Has dev

-- | Update a metric monitoring how many drives are currently
-- undergoing reset. Note that increasing when we start reset and
-- decreasing when we stop reset can provide bad results: consider
-- what happens if we start EKG service half way through a rule doing
-- the marking. We will decrease but haven't increased and we end up
-- with reported data being wrong.
updateDiskResetCount :: PhaseM RC l ()
updateDiskResetCount = do
  i <- fromIntegral . length <$> lookupStorageDevicesWithAttr SDOnGoingReset
  runEkgMetricCmd (ModifyGauge "ongoing_disk_resets" $ GaugeSet i)

-- | Test whether a given device is currently undergoing a reset operation.
hasOngoingReset :: StorageDevice -> PhaseM RC l Bool
hasOngoingReset =
    fmap (not . null) . findStorageDeviceAttrs go
  where
    go SDOnGoingReset = True
    go _              = False

-- | Mark that a storage device is undergoing reset.
markOnGoingReset :: StorageDevice -> PhaseM RC l ()
markOnGoingReset sdev = do
    let _F SDOnGoingReset = True
        _F _                 = False
    m <- listToMaybe <$> findStorageDeviceAttrs _F sdev
    case m of
      Nothing -> do
        setStorageDeviceAttr sdev SDOnGoingReset
        updateDiskResetCount
      _       -> return ()

-- | Mark that a storage device has completed reset.
markResetComplete :: StorageDevice -> PhaseM RC l ()
markResetComplete sdev = do
    let _F SDOnGoingReset = True
        _F _                 = False
    m <- listToMaybe <$> findStorageDeviceAttrs _F sdev
    case m of
      Nothing  -> return ()
      Just old -> do
        unsetStorageDeviceAttr sdev old
        updateDiskResetCount

incrDiskResetAttempts :: StorageDevice -> PhaseM RC l ()
incrDiskResetAttempts sdev = do
    let _F (SDResetAttempts _) = True
        _F _                        = False
    m <- listToMaybe <$> findStorageDeviceAttrs _F sdev
    case m of
      Just old@(SDResetAttempts i) -> do
        unsetStorageDeviceAttr sdev old
        setStorageDeviceAttr sdev (SDResetAttempts (i+1))
      _ -> setStorageDeviceAttr sdev (SDResetAttempts 1)

getDiskResetAttempts :: StorageDevice -> PhaseM RC l Int
getDiskResetAttempts sdev = do
  let _F (SDResetAttempts _) = True
      _F _                   = False
  m <- listToMaybe <$> findStorageDeviceAttrs _F sdev
  case m of
    Just (SDResetAttempts i) -> return i
    _                        -> return 0

-- | Find 'Node's that are in the same 'Enclosure' as the given
-- 'StorageDevice'.
--
-- TODO: Should be @'Maybe' 'Node'@.
-- TODO: Is this function and are uses of this function correct?
-- TODO: Same questions for 'getSDevHost'
getSDevNode :: StorageDevice -> PhaseM RC l [Node]
getSDevNode sdev = do
  rg <- getLocalGraph
  hosts <- getSDevHost sdev
  return [ node | host <- hosts
                , node <- G.connectedTo host Runs rg ]

-- | Find 'Host's that are in the same 'Enclosure' as the given
-- 'StorageDevice'.
--
-- TODO: See 'getSDevNode' TODOs.
getSDevHost :: StorageDevice -> PhaseM RC l [Host]
getSDevHost sdev = do
  rg <- getLocalGraph
  return [ host
         | Just encl <- [G.connectedFrom Has sdev rg :: Maybe Enclosure]
         , host <- G.connectedTo encl Has rg :: [Host]
         ]

-- | Set an attribute on a storage device.
setStorageDeviceAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM RC l ()
setStorageDeviceAttr sd attr  = do
  actLog "setStorageDeviceAttr" [("sd", show sd), ("attr", show attr)]
  modifyGraph $ G.connect sd Has attr

-- | Unset an attribute on a storage device.
unsetStorageDeviceAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM RC l ()
unsetStorageDeviceAttr sd attr = do
  actLog "unsetStorageDeviceAttr" [("sd", show sd), ("attr", show attr)]
  modifyGraph $ G.disconnect sd Has attr

-- | Find attributes matching the given filter on a storage device.
findStorageDeviceAttrs :: (StorageDeviceAttr -> Bool)
                       -> StorageDevice
                       -> PhaseM RC l [StorageDeviceAttr]
findStorageDeviceAttrs k sdev = do
    rg <- getLocalGraph
    return [ attr | attr <- G.connectedTo sdev Has rg :: [StorageDeviceAttr]
                  , k attr
                  ]
