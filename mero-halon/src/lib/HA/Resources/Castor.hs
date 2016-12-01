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

{-# OPTIONS_GHC -fno-warn-orphans       #-}

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
deriveSafeCopy 0 'base ''Rack

-- | Representation of a physical enclosure.
newtype Enclosure = Enclosure
    String -- ^ Enclosure UUID.
  deriving (Eq, Show, Generic, Typeable, Hashable)
deriveSafeCopy 0 'base ''Enclosure

-- | Representation of a physical host.
newtype Host = Host
    String -- ^ Hostname
  deriving (Eq, Show, Generic, Typeable, Hashable, FromJSON, ToJSON, Ord)
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
deriveSafeCopy 0 'base ''HostAttr

-- | Representation of a storage device
newtype StorageDevice = StorageDevice
    UUID -- ^ Internal UUID used to refer to the disk
  deriving (Eq, Show, Ord, Generic, Typeable, Hashable)

instance FromJSON StorageDevice
instance ToJSON StorageDevice

deriveSafeCopy 0 'base ''StorageDevice

data StorageDeviceAttr
    = SDResetAttempts !Int
    | SDPowered Bool
    | SDOnGoingReset
    | SDRemovedAt
    | SDReplaced
    | SDRemovedFromRAID
    deriving (Eq, Ord, Show, Generic)

instance Hashable StorageDeviceAttr
deriveSafeCopy 0 'base ''StorageDeviceAttr

-- | Arbitrary identifier for a logical or storage device
data DeviceIdentifier =
      DIPath String
    | DIIndexInEnclosure Int
    | DIWWN String
    | DIUUID String
    | DISerialNumber String
    | DIRaidIdx Int -- Index in RAID array
    | DIRaidDevice String -- Device name of RAID device containing this
  deriving (Eq, Show, Ord, Generic, Typeable)

instance Hashable DeviceIdentifier
instance ToJSON DeviceIdentifier
instance FromJSON DeviceIdentifier
deriveSafeCopy 0 'base ''DeviceIdentifier

-- | Representation of storage device status. Currently this just mirrors
--   the status we get from OpenHPI.
data StorageDeviceStatus = StorageDeviceStatus
    { sdsStatus :: String
    , sdsReason :: String
    }
  deriving (Eq, Show, Generic, Typeable)

instance Hashable StorageDeviceStatus
deriveSafeCopy 0 'base ''StorageDeviceStatus

-- | Marker used to indicate that a host is undergoing RAID reassembly.
data ReassemblingRaid = ReassemblingRaid
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ReassemblingRaid
deriveSafeCopy 0 'base ''ReassemblingRaid
--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | The relation between a configuration object and its state marker.
data Is = Is
    deriving (Eq, Show, Generic, Typeable)

instance Hashable Is
deriveSafeCopy 0 'base ''Is

-- | The relation between a storage device and it's new version.
data ReplacedBy = ReplacedBy deriving (Eq, Show, Generic, Typeable)

instance Hashable ReplacedBy
deriveSafeCopy 0 'base ''ReplacedBy

-- Defined here for the instances to connect to Cluster (so it doesn't
-- get GC'd). Helpers elsewhere.
-- | Collection of variables used throughout rules for things such as
-- timeouts, retry attempt numbers &c. It is encouraged to change
-- these early into the life of the RC to prevent unexpected behaviour
-- when assumptions about constant values inside rules fail.
data HalonVars = HalonVars
  { _hv_recovery_expiry_seconds :: Int
  -- ^ How long we want node recovery to last overall.
  , _hv_recovery_max_retries :: Int
  -- ^ Number of times to try recovery. Set to negative if you want
  -- recovery to last forever. Even if negative, you should still set
  -- it to a sensible number to make sure that
  -- @'_hv_recovery_expiry_seconds' `div` 'abs' '_hv_recovery_max_retries'@
  -- value used for the frequency of recovery still makes sense.
  , _hv_keepalive_frequency :: Int
  -- ^ How often should the keepalive check trigger in the mero
  -- process keepalive rule. Seconds.
  , _hv_keepalive_timeout :: Int
  -- ^ How many seconds to allow for a process to go on without a keepalive
  -- reply coming back.
  , _hv_drive_reset_max_retries :: Int
  -- ^ How many times we want to retry disk reset procedure before giving up.
  , _hv_process_configure_timeout :: Int
  -- ^ How many seconds until process configuration is considered to
  -- be timed out. This includes time spent waiting on @mero-mkfs@.
  , _hv_process_start_cmd_timeout :: Int
  -- ^ How many seconds to wait for a process start command to return.
  -- Note that this is not the same as the time we should wait for a
  -- process to successfully start, for that see
  -- '_hv_process_start_timeout'. For configuration timeout
  -- (@mero-mkfs@ &c.) see '_hv_process_configure_timeout'.
  , _hv_process_start_timeout :: Int
  -- ^ How many seconds to wait for the process to start after the
  -- process start command has completed. For the timeout pertaining
  -- to the timeout of the start command itself, see
  -- '_hv_process_start_cmd_timeout'.
  , _hv_process_max_start_attempts :: Int
  -- ^ How many times to try and start the same process if it fails to
  -- start. Note that if systemctl exits with an unexpected error
  -- code, process start is failed straight away.
  , _hv_process_restart_retry_interval :: Int
  -- ^ How many seconds to wait before we try to start a process again
  -- in case it has failed to start and we haven't met
  -- '_hv_process_max_start_attempts'.
  , _hv_mero_kernel_start_timeout :: Int
  -- ^ How many seconds to wait for halon:m0d (and @mero-kernel@) to
  -- come up and declare channels.
  , _hv_clients_start_timeout :: Int
  -- ^ How many seconds to wait for clients during cluster bootstrap
  -- before giving up on receiving a result.
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable HalonVars
deriveSafeCopy 0 'base ''HalonVars

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- XXX Only nodes and services have runtime information attached to them, for now.
$(mkDicts
  [ ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''MI.Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''StorageDeviceAttr
  , ''MI.BMC, ''UUID, ''ReassemblingRaid, ''HalonVars
  ]
  [ (''Cluster, ''Has, ''Rack)
  , (''Cluster, ''Has, ''Host)
  , (''Cluster, ''Has, ''HalonVars)
  , (''Rack, ''Has, ''Enclosure)
  , (''Host, ''Has, ''MI.Interface)
  , (''Host, ''Has, ''HostAttr)
  , (''Enclosure, ''Has, ''StorageDevice)
  , (''Enclosure, ''Has, ''Host)
  , (''Enclosure, ''Has, ''MI.BMC)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''Host, ''Has, ''StorageDevice)
  -- , (''StorageDevice, ''Has, ''StorageDeviceStatus)
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
  ]
  [ (''Cluster, AtMostOne, ''Has, Unbounded, ''Rack)
  , (''Cluster, AtMostOne, ''Has, Unbounded, ''Host)
  , (''Cluster, AtMostOne, ''Has, AtMostOne, ''HalonVars)
  , (''Rack, AtMostOne, ''Has, Unbounded, ''Enclosure)
  , (''Host, AtMostOne, ''Has, Unbounded, ''MI.Interface)
  , (''Host, Unbounded, ''Has, Unbounded, ''HostAttr)
  , (''Host, AtMostOne, ''Has, AtMostOne, ''UUID)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''StorageDevice)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''Host)
  , (''Enclosure, AtMostOne, ''Has, Unbounded, ''MI.BMC)
  , (''Host, AtMostOne, ''Runs, Unbounded, ''Node)
  , (''StorageDevice, Unbounded, ''Is, AtMostOne, ''StorageDeviceStatus)
  , (''Host, AtMostOne, ''Has, Unbounded, ''StorageDevice)
  -- , (''StorageDevice, Unbounded, ''Has, AtMostOne, ''StorageDeviceStatus)
  , (''StorageDevice, Unbounded, ''Has, Unbounded, ''DeviceIdentifier)
  , (''StorageDevice, Unbounded, ''Has, Unbounded, ''StorageDeviceAttr)
  , (''StorageDevice, AtMostOne, ''ReplacedBy, AtMostOne, ''StorageDevice)
  , (''Host, Unbounded, ''Is, AtMostOne, ''ReassemblingRaid)
  ]
  []
  )
