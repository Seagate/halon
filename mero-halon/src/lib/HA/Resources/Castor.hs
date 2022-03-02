-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Castor specific resources.

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
-- XXX: for graph instances:
{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Resources.Castor
  ( module HA.Resources.Castor
  , BMC(..)
  ) where

import HA.Aeson
import HA.SafeCopy
import HA.Resources (Cluster(..), Has(..), Node(..), Runs(..))
import HA.Resources.Castor.Initial (BMC(..))
import HA.Resources.TH

import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import Data.UUID (UUID)
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

newtype Site = Site Int -- ^ Site index.
  deriving (Eq, Generic, Hashable, Show, Typeable, ToJSON)

storageIndex ''Site "521f5803-9277-40b4-ae5e-6bbb57a25403"
deriveSafeCopy 0 'base ''Site

newtype Rack = Rack Int -- ^ Rack index.
  deriving (Eq, Generic, Hashable, Show, Typeable, ToJSON)

storageIndex ''Rack "227a4ae1-529b-40b0-a0b4-7466605764c2"
deriveSafeCopy 0 'base ''Rack

-- | Representation of a physical enclosure.
newtype Enclosure = Enclosure String -- ^ Enclosure UUID.
  deriving (Eq, Generic, Hashable, Ord, Show, Typeable, FromJSON, ToJSON)

storageIndex ''Enclosure "4e78e1a1-8d02-4f42-a325-a4685aa44595"
deriveSafeCopy 0 'base ''Enclosure

-- | Representation of a physical host.
newtype Host = Host String -- ^ Hostname.
  deriving (Eq, Generic, Hashable, Ord, Show, Typeable, FromJSON, ToJSON)

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
instance ToJSON HostAttr

storageIndex ''HostAttr "7a3def57-d9d2-41e1-9024-a72803916b6b"
deriveSafeCopy 0 'base ''HostAttr

-- | Representation of a storage device.
newtype StorageDevice = StorageDevice
    String -- ^ Disk serial number. XXX: convert to ShortByteString
  deriving (Eq, Generic, Hashable, Ord, Show, Typeable, FromJSON, ToJSON)

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
instance ToJSON StorageDeviceAttr

storageIndex ''StorageDeviceAttr "0a27839d-7e0c-4dda-96b8-034d640e6503"
deriveSafeCopy 0 'base ''StorageDeviceAttr

-- | Arbitrary identifier for a logical or storage device.
data DeviceIdentifier
  = DIPath String
  | DIWWN String
  | DIUUID String
  | DIRaidIdx Int -- Index in RAID array.
  | DIRaidDevice String -- Device name of RAID device containing this.
  deriving (Eq, Generic, Ord, Show, Typeable)

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
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable StorageDeviceStatus
instance ToJSON StorageDeviceStatus

storageIndex ''StorageDeviceStatus "893b1410-6aff-4694-a6fd-19509a12d715"
deriveSafeCopy 0 'base ''StorageDeviceStatus

-- | Marker used to indicate that a host is undergoing RAID reassembly.
data ReassemblingRaid = ReassemblingRaid
  deriving (Eq, Generic, Show, Typeable)

instance Hashable ReassemblingRaid
instance ToJSON ReassemblingRaid

storageIndex ''ReassemblingRaid "e82259ce-5ae8-4117-85ca-6593e3856a89"
deriveSafeCopy 0 'base ''ReassemblingRaid

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | The relation between a configuration object and its state marker.
data Is = Is
  deriving (Eq, Generic, Show, Typeable)

instance Hashable Is
instance ToJSON Is

storageIndex ''Is "72d44ab5-4a22-4dbf-9cf1-170ed8518f3e"
deriveSafeCopy 0 'base ''Is

-- | The relation between a storage device and it's new version.
data ReplacedBy = ReplacedBy
  deriving (Eq, Generic, Show, Typeable)

instance Hashable ReplacedBy
instance ToJSON ReplacedBy

storageIndex ''ReplacedBy "5db0c0d7-59d0-4750-84f6-c4b140a190df"
deriveSafeCopy 0 'base ''ReplacedBy

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
  , _hv_drive_unpowered_timeout :: !Int
  -- ^ How many seconds should we allow for a drive to re-power before
  --   giving up and attempting to mark the drive as failed.
  , _hv_drive_transient_timeout :: !Int
  -- ^ How many seconds should we allow for a drive to sit in transient state
  --   before attempting to move it to a permanent failure.
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
  , _hv_expander_reset_threshold :: !Int
  -- ^ Minimum number of drives we would expect to see failing in the case of
  --   an expander reset.
  , _hv_expander_reset_reset_timeout :: !Int
  -- ^ Number of seconds to wait following an inferred expander reset for drives
  --   to come back online before attempting to reset them.
  , _hv_notification_timeout :: !Int
  -- ^ Number of seconds to wait for all notifications to be acknowledged by
  --   the system (or for them to be cancelled due to process failure).
  --   This should be lower than any timeout which waits (in a rule) for all
  --   notifications to be acknowledged.
  , _hv_notification_aggr_delay :: !Int
  -- ^ How long to wait for a new notification to add into the aggregation
  --   (in ms).
  , _hv_notification_aggr_max_delay :: !Int
  -- ^ How long to aggregate notifications before sending them (in ms).
  , _hv_failed_notification_fails_process :: !Bool
  -- ^ Determine whether a process should be considered as failed if we cannot
  --   send a notification to it. Generally we want this, but it can sometimes
  --   cause problems.
  , _hv_sns_operation_status_attempts :: !Int
  -- ^ How many times to ask for the status of SNS operation before giving up
  --   and retrying.
  , _hv_sns_operation_retry_attempts :: !Int
  -- ^ How many attempts to execute SNS operation to make before giving up
  --   and failing.
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable HalonVars
instance ToJSON HalonVars

storageIndex ''HalonVars "46828e80-3122-45e1-88b9-1ba3edea13ae"
deriveSafeCopy 0 'base ''HalonVars

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- XXX Only nodes and services have runtime information attached to them, for now.
$(mkDicts
  [ ''Site, ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''StorageDevice
  , ''StorageDeviceStatus, ''StorageDeviceAttr
  , ''BMC, ''UUID, ''ReassemblingRaid, ''HalonVars
  , ''Slot, ''Is, ''ReplacedBy
  ]
  [ (''Cluster, ''Has, ''Site)
  , (''Cluster, ''Has, ''Host)
  , (''Cluster, ''Has, ''HalonVars)
  , (''Cluster, ''Has, ''StorageDevice)
  , (''Site, ''Has, ''Rack)
  , (''Rack, ''Has, ''Enclosure)
  , (''Host, ''Has, ''HostAttr)
  , (''Enclosure, ''Has, ''Slot)
  , (''StorageDevice, ''Has, ''Slot)
  , (''Enclosure, ''Has, ''Host)
  , (''Enclosure, ''Has, ''BMC)
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
  [ ''Site, ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''StorageDevice
  , ''StorageDeviceStatus, ''StorageDeviceAttr
  , ''BMC, ''UUID, ''ReassemblingRaid, ''HalonVars
  , ''Slot, ''Is, ''ReplacedBy
  ]
  [ (''Cluster, AtMostOne, ''Has, Unbounded, ''Site)
  , (''Cluster, AtMostOne, ''Has, Unbounded, ''Host)
  , (''Cluster, AtMostOne, ''Has, AtMostOne, ''HalonVars)
  , (''Cluster, AtMostOne, ''Has, Unbounded, ''StorageDevice)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''Slot)
  , (''Site, AtMostOne, ''Has, Unbounded, ''Rack)
  , (''Rack, AtMostOne, ''Has, Unbounded, ''Enclosure)
  , (''Host, Unbounded, ''Has, Unbounded, ''HostAttr)
  , (''Host, AtMostOne, ''Has, AtMostOne, ''UUID)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''Host)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''BMC)
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
