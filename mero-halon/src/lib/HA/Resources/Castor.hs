-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Castor specific resources.

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- XXX: for graph instances:
{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Resources.Castor (
    module HA.Resources.Castor
  , MI.BMC(..)
  , MI.Interface(..)
) where

import HA.Aeson
import HA.SafeCopy
import HA.Resources
import qualified HA.Resources.Castor.Initial as MI
import HA.Resources.TH

import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import Data.UUID (UUID)
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

newtype Rack = Rack
  Int -- ^ Rack index
  deriving (Eq, Show, Generic, Typeable, Hashable)
storageIndex ''Rack "227a4ae1-529b-40b0-a0b4-7466605764c2"
deriveSafeCopy 0 'base ''Rack
instance ToJSON Rack

-- | Representation of a physical enclosure.
newtype Enclosure = Enclosure String -- ^ Enclosure UUID.
  deriving (Eq, Show, Ord, Generic, Typeable, Hashable)
instance FromJSON Enclosure
instance ToJSON   Enclosure
storageIndex ''Enclosure "4e78e1a1-8d02-4f42-a325-a4685aa44595"
deriveSafeCopy 0 'base ''Enclosure

-- | Representation of a physical host.
newtype Host = Host
    String -- ^ Hostname
  deriving (Eq, Show, Generic, Typeable, Hashable, FromJSON, ToJSON, Ord)
storageIndex ''Host "8a9fb3e8-5400-45d4-85a3-e7d5128e504b"
deriveSafeCopy 0 'base ''Host

-- | Generic 'host attribute'.
data HostAttr =
    HA_POWERED
  | HA_TSNODE
  | HA_M0CLIENT
  | HA_M0SERVER
  | HA_MEMSIZE_MB Int
  | HA_CPU_COUNT Int
  | HA_TRANSIENT
    -- ^ The host is marked as transient. This is a simple indication
    -- that we should try to reach the node and have it announce
    -- itself to the RC.
  | HA_DOWN
    -- ^ Node has been marked as down. We have tried to recover from
    -- the node failure in the past ('HA_TRANSIENT') but have failed
    -- to do so in timely manner.
  deriving (Eq, Ord, Show, Generic, Typeable)

instance Hashable HostAttr
storageIndex ''HostAttr "7a3def57-d9d2-41e1-9024-a72803916b6b"
deriveSafeCopy 0 'base ''HostAttr
instance ToJSON HostAttr

-- | Representation of a storage device
newtype StorageDevice = StorageDevice
    String -- ^ Disk serial number. XXX: convert to ShortByteString
  deriving (Eq, Show, Ord, Generic, Typeable, Hashable)

instance FromJSON StorageDevice
instance ToJSON StorageDevice

storageIndex ''StorageDevice "6f7915aa-645c-42b4-b3e0-a8222c764730"
deriveSafeCopy 0 'base ''StorageDevice

data Slot = Slot
  { slotEnclosure :: Enclosure
  , slotIndex     :: Int
  } deriving (Eq, Show, Ord, Generic, Typeable)
instance Hashable Slot
instance FromJSON Slot
instance ToJSON   Slot

storageIndex ''Slot "b0561c97-63ed-4f16-a27a-10ef04f9a023"
deriveSafeCopy 0 'base ''Slot


data StorageDeviceAttr
    = SDResetAttempts !Int
    | SDPowered Bool
    | SDOnGoingReset
    | SDRemovedFromRAID
    deriving (Eq, Ord, Show, Generic)

instance Hashable StorageDeviceAttr
storageIndex ''StorageDeviceAttr "0a27839d-7e0c-4dda-96b8-034d640e6503"
deriveSafeCopy 0 'base ''StorageDeviceAttr
instance ToJSON StorageDeviceAttr

-- | Arbitrary identifier for a logical or storage device
data DeviceIdentifier =
      DIPath String
    | DIWWN String
    | DIUUID String
    | DIRaidIdx Int -- Index in RAID array
    | DIRaidDevice String -- Device name of RAID device containing this
  deriving (Eq, Show, Ord, Generic, Typeable)

instance Hashable DeviceIdentifier
instance ToJSON DeviceIdentifier
instance FromJSON DeviceIdentifier
storageIndex ''DeviceIdentifier "d4b502aa-e1d3-421a-8082-f3837aef3fdc"
deriveSafeCopy 0 'base ''DeviceIdentifier

-- | Representation of storage device status. Currently this just mirrors
--   the status we get from OpenHPI.
data StorageDeviceStatus = StorageDeviceStatus
    { sdsStatus :: String
    , sdsReason :: String
    }
  deriving (Eq, Show, Generic, Typeable)

instance Hashable StorageDeviceStatus
storageIndex ''StorageDeviceStatus "893b1410-6aff-4694-a6fd-19509a12d715"
deriveSafeCopy 0 'base ''StorageDeviceStatus
instance ToJSON StorageDeviceStatus

-- | Marker used to indicate that a host is undergoing RAID reassembly.
data ReassemblingRaid = ReassemblingRaid
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ReassemblingRaid
storageIndex ''ReassemblingRaid "e82259ce-5ae8-4117-85ca-6593e3856a89"
deriveSafeCopy 0 'base ''ReassemblingRaid
instance ToJSON ReassemblingRaid

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | The relation between a configuration object and its state marker.
data Is = Is
    deriving (Eq, Show, Generic, Typeable)

instance Hashable Is
storageIndex ''Is "72d44ab5-4a22-4dbf-9cf1-170ed8518f3e"
deriveSafeCopy 0 'base ''Is
instance ToJSON Is

-- | The relation between a storage device and it's new version.
data ReplacedBy = ReplacedBy
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ReplacedBy
storageIndex ''ReplacedBy "5db0c0d7-59d0-4750-84f6-c4b140a190df"
deriveSafeCopy 0 'base ''ReplacedBy
instance ToJSON ReplacedBy

-- Defined here for the instances to connect to Cluster (so it doesn't
-- get GC'd). Helpers elsewhere.
-- | Collection of variables used throughout rules for things such as
-- timeouts, retry attempt numbers &c. It is encouraged to change
-- these early into the life of the RC to prevent unexpected behaviour
-- when assumptions about constant values inside rules fail.
data HalonVars = HalonVars
  { _hv_recovery_expiry_seconds :: !Int
  -- ^ How long we want node recovery to last overall.
  , _hv_recovery_max_retries :: !Int
  -- ^ Number of times to try recovery. Set to negative if you want
  -- recovery to last forever. Even if negative, you should still set
  -- it to a sensible number to make sure that
  -- @'_hv_recovery_expiry_seconds' `div` 'abs' '_hv_recovery_max_retries'@
  -- value used for the frequency of recovery still makes sense.
  , _hv_keepalive_frequency :: !Int
  -- ^ How often should the keepalive check trigger in the mero
  -- process keepalive rule. Seconds.
  , _hv_keepalive_timeout :: !Int
  -- ^ How many seconds to allow for a process to go on without a keepalive
  -- reply coming back.
  , _hv_drive_reset_max_retries :: !Int
  -- ^ How many times we want to retry disk reset procedure before giving up.
  , _hv_process_configure_timeout :: !Int
  -- ^ How many seconds until process configuration is considered to
  -- be timed out. This includes time spent waiting on @mero-mkfs@.
  , _hv_process_start_cmd_timeout :: !Int
  -- ^ How many seconds to wait for a process start command to return.
  -- Note that this is not the same as the time we should wait for a
  -- process to successfully start, for that see
  -- '_hv_process_start_timeout'. For configuration timeout
  -- (@mero-mkfs@ &c.) see '_hv_process_configure_timeout'.
  , _hv_process_start_timeout :: !Int
  -- ^ How many seconds to wait for the process to start after the
  -- process start command has completed. For the timeout pertaining
  -- to the timeout of the start command itself, see
  -- '_hv_process_start_cmd_timeout'.
  , _hv_process_stop_timeout :: !Int
  -- ^ How many seconds to wait for the process to stop after the
  -- process stop command has been issued.
  , _hv_process_max_start_attempts :: !Int
  -- ^ How many times to try and start the same process if it fails to
  -- start. Note that if systemctl exits with an unexpected error
  -- code, process start is failed straight away.
  , _hv_process_restart_retry_interval :: !Int
  -- ^ How many seconds to wait before we try to start a process again
  -- in case it has failed to start and we haven't met
  -- '_hv_process_max_start_attempts'.
  , _hv_mero_kernel_start_timeout :: !Int
  -- ^ How many seconds to wait for @halon:m0d@ (and @mero-kernel@) to
  -- come up and declare channels.
  , _hv_clients_start_timeout :: !Int
  -- ^ How many seconds to wait for clients during cluster bootstrap
  -- before giving up on receiving a result.
  , _hv_node_stop_barrier_timeout :: !Int
  -- ^ How many seconds a node should wait for a cluster to transition
  -- into the desired bootlevel during teardown procedure before
  -- timing out.
  , _hv_drive_insertion_timeout :: !Int
  -- ^ How many seconds should we allow for new drive
  -- insertion/removal events in the disk slot before proceeding with
  -- drive insertion procedures.
  , _hv_drive_removal_timeout :: !Int
  -- ^ How many seconds should we wait for drive re-insertion before
  -- giving up and considering drive as removed.
  , _hv_expander_node_up_timeout :: !Int
  -- ^ How many seconds to wait for a node to finish restarting
  -- processes during expander reset.
  , _hv_expander_sspl_ack_timeout :: !Int
  -- ^ How many seconds to wait for SSPL to reply during expander reset.
  , _hv_monitoring_angel_delay :: !Int
  -- ^ How many seconds should the node monitor angel wait without
  -- receiving any commands and deciding to send heartbeat to
  -- monitored nodes.
  , _hv_mero_workers_allowed :: !Bool
  -- ^ Whether to run allow running of mero workers. It may happen
  -- we're on a system where it's not possible to actually run mero
  -- but some actions which require it are performed. This flag
  -- indicates to those functions that they should do ‘something else’
  -- instead of starting the mero worker and performing the task. What
  -- this is depends on the function itself: it does not fundamentally
  -- prevent calls to initialize the workers.
  --
  -- This is mainly used for testing of components that don't rely on
  -- the result of the tasks normally performed by mero workers for
  -- main functionality. You probably __never__ want to set this on an
  -- actual deployment.
  , _hv_disable_smart_checks :: !Bool
  -- ^ Disable smart tests of the disks. If smart test is disabled
  -- all calls to smart test automatically successful.
  , _hv_service_stop_timeout :: !Int
  -- ^ How long to wait for a service to stop (perform teardown and
  -- exit) before the calling rule decides to stop waiting for result.
  , _hv_m0dixinit_timeout :: !Int
  -- ^ How long to wait for m0dixinit to complete before the calling
  --   rule decides that it has failed.
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable HalonVars
storageIndex ''HalonVars "46828e80-3122-45e1-88b9-1ba3edea13ae"
deriveSafeCopy 0 'base ''HalonVars
instance ToJSON HalonVars

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- XXX Only nodes and services have runtime information attached to them, for now.
$(mkDicts
  [ ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''MI.Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''StorageDeviceAttr
  , ''MI.BMC, ''UUID, ''ReassemblingRaid, ''HalonVars
  , ''Slot, ''Is, ''ReplacedBy
  ]
  [ (''Cluster, ''Has, ''Rack)
  , (''Cluster, ''Has, ''Host)
  , (''Cluster, ''Has, ''HalonVars)
  , (''Cluster, ''Has, ''StorageDevice)
  , (''Rack, ''Has, ''Enclosure)
  , (''Host, ''Has, ''MI.Interface)
  , (''Host, ''Has, ''HostAttr)
  , (''Enclosure, ''Has, ''Slot)
  , (''StorageDevice, ''Has, ''Slot)
  , (''Enclosure, ''Has, ''Host)
  , (''Enclosure, ''Has, ''MI.BMC)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''StorageDevice, ''Has, ''DeviceIdentifier)
  , (''StorageDevice, ''Has, ''StorageDeviceAttr)
  , (''StorageDevice, ''ReplacedBy, ''StorageDevice)
  , (''Host, ''Has, ''UUID)
  , (''Host, ''Is, ''ReassemblingRaid)
  ]
  )

$(mkResRel
  [ ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''MI.Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''StorageDeviceAttr
  , ''MI.BMC, ''UUID, ''ReassemblingRaid, ''HalonVars
  , ''Slot, ''Is, ''ReplacedBy
  ]
  [ (''Cluster, AtMostOne, ''Has, Unbounded, ''Rack)
  , (''Cluster, AtMostOne, ''Has, Unbounded, ''Host)
  , (''Cluster, AtMostOne, ''Has, AtMostOne, ''HalonVars)
  , (''Cluster, AtMostOne, ''Has, Unbounded, ''StorageDevice)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''Slot)
  , (''Rack, AtMostOne, ''Has, Unbounded, ''Enclosure)
  , (''Host, AtMostOne, ''Has, Unbounded, ''MI.Interface)
  , (''Host, Unbounded, ''Has, Unbounded, ''HostAttr)
  , (''Host, AtMostOne, ''Has, AtMostOne, ''UUID)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''Host)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''MI.BMC)
  , (''Host, AtMostOne, ''Runs, Unbounded, ''Node)
  , (''StorageDevice, Unbounded, ''Is, AtMostOne, ''StorageDeviceStatus)
  , (''StorageDevice, AtMostOne, ''Has, AtMostOne, ''Slot)
  , (''StorageDevice, Unbounded, ''Has, Unbounded, ''DeviceIdentifier)
  , (''StorageDevice, Unbounded, ''Has, Unbounded, ''StorageDeviceAttr)
  , (''StorageDevice, AtMostOne, ''ReplacedBy, AtMostOne, ''StorageDevice)
  , (''Host, Unbounded, ''Is, AtMostOne, ''ReassemblingRaid)
  ]
  []
  )
