{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE PackageImports             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# OPTIONS_GHC -fno-warn-orphans       #-}

-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero specific resources in Halon.
-- Should be imported qualified:
-- import qualified HA.Resources.Mero as M0

module HA.Resources.Mero
  ( module HA.Resources.Mero
  , CI.M0Globals
  ) where

import Control.Distributed.Process (ProcessId)
import qualified HA.Resources as R
import HA.Resources.TH
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI

import Mero.ConfC
  ( Bitmap
  , Fid(..)
  , PDClustAttr(..)
  , ServiceParams
  , ServiceType
  )

import Data.Aeson
import Data.Aeson.Types (typeMismatch)
import Data.Binary (Binary(..))
import Data.Bits
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.Function (on)
import Data.Hashable (Hashable(..))
import Data.Int (Int64)
import Data.Proxy (Proxy(..))
import Data.Scientific
import Data.Typeable (Typeable)
import qualified Data.Vector as V
import Data.Word ( Word32, Word64 )
import GHC.Generics (Generic)
import qualified "distributed-process-scheduler" System.Clock as C

import Data.Maybe (listToMaybe)
import Data.UUID (UUID)
import qualified HA.ResourceGraph as G
--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | Fid type mask
typMask :: Word64
typMask = 0x00ffffffffffffff

-- | Fid generation sequence number
newtype FidSeq = FidSeq Word64
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

-- | Couple of utility methods for conf objects. Minimal implementation:
--   fidType and fid
class ConfObj a where

  -- Return the fid type of the conf object.
  fidType :: Proxy a
          -> Word64

  fidInit :: Proxy a
          -> Word64 -- container
          -> Word64 -- key
          -> Fid
  fidInit p cont key = Fid {
        f_container = container
      , f_key = key
      }
    where
      -- The top 8 bits of f_container specify the object type.
      typ = fidType p
      container = (typ `shiftL` (64 - 8)) .|. (cont .&. typMask)

  -- | Return the Mero fid for the given conf object
  fid :: a -> Fid
  {-# MINIMAL fidType, fid #-}

-- | Test if a given fid corresponds to the given type.
fidIsType :: ConfObj a
          => Proxy a
          -> Fid
          -> Bool
fidIsType p (Fid ctr _) =
  (ctr .&. (complement typMask)) == (fidType p `shiftL` (64 - 8))

data AnyConfObj = forall a. ConfObj a => AnyConfObj a

data SpielAddress = SpielAddress {
    sa_confds_fid :: [Fid]
  , sa_confds_ep :: [String]
  , sa_rm_fid :: Fid
  , sa_rm_ep :: String
}  deriving (Eq, Generic, Show, Typeable)

instance Binary SpielAddress
instance Hashable SpielAddress

data SyncToConfd =
      SyncToConfdServersInRG
    | SyncDumpToBS ProcessId
  deriving (Eq, Generic, Show, Typeable)

instance Binary SyncToConfd
instance Hashable SyncToConfd

newtype SyncDumpToBSReply = SyncDumpToBSReply (Either String BS.ByteString)
  deriving (Eq, Generic, Show, Typeable)

instance Binary SyncDumpToBSReply
instance Hashable SyncDumpToBSReply

--------------------------------------------------------------------------------
-- Conf tree in the resource graph
--------------------------------------------------------------------------------

-- | The relation between a configuration object and the runtime resource
-- representing it.
-- Directed from configuration object to Halon resource
-- (e.g. M0.Controller At Host)
data At = At
    deriving (Eq, Show, Generic, Typeable)

instance Binary At
instance Hashable At

-- | Relationship between parent and child entities in confd
--   Directed from parent to child (e.g. profile IsParentOf filesystem)
data IsParentOf = IsParentOf
   deriving (Eq, Generic, Show, Typeable)

instance Binary IsParentOf
instance Hashable IsParentOf

-- | Relationship between virtual and real entities in confd.
--   Directed from real to virtual (e.g. pool IsRealOf pver)
data IsRealOf = IsRealOf
   deriving (Eq, Generic, Show, Typeable)

instance Binary IsRealOf
instance Hashable IsRealOf

-- | Relationship between conceptual and hardware entities in confd
--   Directed from sdev to disk (e.g. sdev IsOnHardware disk)
--   Directed from node to controller (e.g. node IsOnHardware controller)
data IsOnHardware = IsOnHardware
   deriving (Eq, Generic, Show, Typeable)

instance Binary IsOnHardware
instance Hashable IsOnHardware

newtype Root = Root Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Root where
   fidType _ = fromIntegral . ord $ 't'
   fid (Root f) = f

newtype Profile = Profile Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable, FromJSON, ToJSON)

instance ConfObj Profile where
  fidType _ = fromIntegral . ord $ 'p'
  fid (Profile f) = f

data Filesystem = Filesystem {
    f_fid :: Fid
  , f_mdpool_fid :: Fid -- ^ Fid of filesystem metadata pool
} deriving (Eq, Generic, Show, Typeable)

instance Binary Filesystem
instance Hashable Filesystem
instance ToJSON Filesystem
instance FromJSON Filesystem

instance ConfObj Filesystem where
  fidType _ = fromIntegral . ord $ 'f'
  fid = f_fid

newtype Node = Node Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable, Ord)

instance ConfObj Node where
  fidType _ = fromIntegral . ord $ 'n'
  fid (Node f) = f

newtype Rack = Rack Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Rack where
  fidType _ = fromIntegral . ord $ 'a'
  fid (Rack f) = f

newtype Pool = Pool Fid
  deriving
    (Binary, Eq, Generic, Hashable, Show, Typeable, Ord, FromJSON, ToJSON)

instance ConfObj Pool where
  fidType _ = fromIntegral . ord $ 'o'
  fid (Pool f) = f

data Process = Process {
    r_fid :: Fid
  , r_mem_as :: Word64
  , r_mem_rss :: Word64
  , r_mem_stack :: Word64
  , r_mem_memlock :: Word64
  , r_cores :: Bitmap
  , r_endpoint :: String
} deriving (Eq, Generic, Show, Typeable)

instance Binary Process
instance Hashable Process
instance ToJSON Process
instance FromJSON Process
instance ToJSON Bitmap
instance FromJSON Bitmap
instance ConfObj Process where
  fidType _ = fromIntegral . ord $ 'r'
  fid = r_fid

data Service = Service {
    s_fid :: Fid
  , s_type :: ServiceType -- ^ e.g. ioservice, haservice
  , s_endpoints :: [String]
  , s_params :: ServiceParams
} deriving (Eq, Generic, Show, Typeable)

instance Binary Service
instance Hashable Service
instance ToJSON Service
instance FromJSON Service
instance ConfObj Service where
  fidType _ = fromIntegral . ord $ 's'
  fid = s_fid

-- | Service state. This is a generalisation of what might be reported to Mero.
data ServiceState =
    SSUnknown -- ^ Service state is not known.
  | SSOffline -- ^ Service is stopped.
  | SSFailed -- ^ Service has failed.
  | SSOnline -- ^ Service is running OK.
  | SSStarting
  | SSStopping
  | SSInhibited ServiceState -- ^ Service state is masked by a higher level
                             --   failure.
  deriving (Eq, Show, Typeable, Generic)
instance Binary ServiceState
instance Hashable ServiceState
instance ToJSON ServiceState
instance FromJSON ServiceState

prettyServiceState :: ServiceState -> String
prettyServiceState SSUnknown = "N/A"
prettyServiceState SSOffline = "offline"
prettyServiceState SSStarting = "starting"
prettyServiceState SSOnline   = "online"
prettyServiceState SSStopping = "stopping"
prettyServiceState SSFailed   = "failed"
prettyServiceState (SSInhibited st) = "inhibited (" ++ prettyServiceState st ++ ")"

data SDev = SDev {
    d_fid :: Fid
  , d_idx :: Word32 -- ^ Index of device in pool
  , d_size :: Word64 -- ^ Size in mb
  , d_bsize :: Word32 -- ^ Block size in mb
  , d_path :: String -- ^ Path to logical device
} deriving (Eq, Generic, Show, Typeable, Ord)

instance Binary SDev
instance Hashable SDev
instance ToJSON SDev
instance FromJSON SDev
instance ConfObj SDev where
  fidType _ = fromIntegral . ord $ 'd'
  fid = d_fid

data SDevState =
    SDSUnknown
  | SDSOnline
  | SDSFailed
  | SDSRepairing
  | SDSRepaired
  | SDSRebalancing
  | SDSTransient SDevState -- Transient failure, and state before said
                           -- transient failure.
  deriving (Eq, Show, Typeable, Generic)

instance Binary SDevState
instance Hashable SDevState
instance ToJSON SDevState
instance FromJSON SDevState

prettySDevState :: SDevState -> String
prettySDevState SDSUnknown = "Unknown"
prettySDevState SDSOnline = "Online"
prettySDevState SDSFailed = "Failed"
prettySDevState SDSRepairing = "Repairing"
prettySDevState SDSRepaired = "Repaired"
prettySDevState SDSRebalancing = "Rebalancing"
prettySDevState (SDSTransient x) = "Transient failure (" ++ prettySDevState x ++ ")"

-- | Transiently fail a drive in an existing state. Most of the time
--   this will result in @x@ becoming @SDSTransient x@, but with exceptions
--   where the device is failed or already transient.
sdsFailTransient :: SDevState -> SDevState
sdsFailTransient SDSFailed = SDSFailed
sdsFailTransient s@(SDSTransient _) = s
sdsFailTransient x = SDSTransient x

-- | Update state following recovery from a transient failure. In general
--   this should restore the previous state.
sdsRecoverTransient :: SDevState -> SDevState
sdsRecoverTransient (SDSTransient x) = x
sdsRecoverTransient y = y

newtype Enclosure = Enclosure Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Enclosure where
  fidType _ = fromIntegral . ord $ 'e'
  fid (Enclosure f) = f

newtype Controller = Controller Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Controller where
  fidType _ = fromIntegral . ord $ 'c'
  fid (Controller f) = f

newtype Disk = Disk Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable, Ord)

instance ConfObj Disk where
  fidType _ = fromIntegral . ord $ 'k'
  fid (Disk f) = f

data PVerType = PVerActual {
    v_tolerance :: [Word32]
  , v_attrs :: PDClustAttr
} | PVerFormulaic {
    v_id :: Word32
  , v_allowance :: [Word32]
  , v_base  :: Fid
} deriving (Eq, Generic, Show, Typeable)

instance Binary PVerType
instance Hashable PVerType

data PVer = PVer {
    v_fid :: Fid
  , v_type :: PVerType
} deriving (Eq, Generic, Show, Typeable)

instance Binary PVer
instance Hashable PVer

newtype PVerCounter = PVerCounter Word32
  deriving (Binary, Eq, Generic, Show, Typeable, Ord, Hashable)

instance ConfObj PVer where
  fidType _ = fromIntegral . ord $ 'v'
  fid = v_fid

newtype RackV = RackV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj RackV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (RackV f) = f

newtype EnclosureV = EnclosureV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj EnclosureV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (EnclosureV f) = f

newtype ControllerV = ControllerV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj ControllerV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (ControllerV f) = f

newtype DiskV = DiskV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj DiskV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (DiskV f) = f

-- | Wrapper for 'C.TimeSpec' providing 'Binary' and 'Hashable'
-- instances.
--
-- Normally you should use 'mkTimeSpec' to create these.
newtype TimeSpec = TimeSpec { _unTimeSpec :: C.TimeSpec }
  deriving (Eq, Num, Ord, Read, Show, Generic, Typeable)

-- | Create a 'TimeSpec' with the given number of seconds.
mkTimeSpec :: Int64 -> TimeSpec
mkTimeSpec sec = TimeSpec { _unTimeSpec = C.TimeSpec sec 0 }

instance ToJSON TimeSpec where
  toJSON (TimeSpec (C.TimeSpec secs nsecs)) =
    Array $ V.fromList [ toJSON secs, toJSON nsecs ]

instance FromJSON TimeSpec where
  parseJSON = withArray "TimeSpec" $ \a ->
      if V.length a /= 2 then do
        let withIntegral expected f = withScientific expected $ \s ->
              case floatingOrInteger s of
                Left (_ :: Double) -> typeMismatch expected (Number s)
                Right i            -> f i
        secs <- withIntegral "secs" return $ (a V.! 0)
        nsecs <- withIntegral "nsecs" return $ (a V.! 1)
        return $ TimeSpec $ C.TimeSpec secs nsecs
      else typeMismatch "TimeSpec" (Array a)

-- | Extract the seconds value from a 'TimeSpec'
--
-- Warning: casts from 'Int64' to 'Int'.
timeSpecToSeconds :: TimeSpec -> Int
timeSpecToSeconds (TimeSpec (C.TimeSpec sec _)) = fromIntegral sec

instance Hashable TimeSpec where
  hashWithSalt s (TimeSpec (C.TimeSpec sec nsec)) = hashWithSalt s (sec, nsec)

instance Binary TimeSpec where
  put (TimeSpec (C.TimeSpec sec nsec)) = put (sec, nsec)
  get = get >>= \(sec, nsec) -> return (TimeSpec $ C.TimeSpec sec nsec)

-- | Get current time using a 'C.Monotonic' 'C.Clock'.
getTime :: IO TimeSpec
getTime = TimeSpec <$> C.getTime C.Monotonic

-- | Classifies 'PoolRepairInformation'. By the time we get
-- information back from mero about the status of the pool, we no
-- longer know whether we have been recovering from failure or whether
-- we're just rebalancing.
--
-- We use this as an indicator. The underlying assumption is that a
-- repair and rebalance will never happen at the same time.
data PoolRepairType = Failure | Rebalance
  deriving (Eq, Show, Ord, Generic, Typeable)

instance Binary PoolRepairType
instance Hashable PoolRepairType

-- | Information attached to 'PoolRepairStatus'.
data PoolRepairInformation = PoolRepairInformation
  { priOnlineNotifications :: Int
  , priTimeOfFirstCompletion :: TimeSpec
  , priTimeLastHourlyRan :: TimeSpec
  , priStateUpdates      :: [(SDev, Int)]
  } deriving (Eq, Show, Generic, Typeable)

instance Binary PoolRepairInformation
instance Hashable PoolRepairInformation
instance ToJSON PoolRepairInformation
instance FromJSON PoolRepairInformation

-- | Sets default values for 'PoolRepairInformation'.
--
-- Number of received notifications is set to 0. The query times are
-- set to 0 seconds after epoch ensuring they queries actually start
-- on the first invocation.
defaultPoolRepairInformation :: PoolRepairInformation
defaultPoolRepairInformation = PoolRepairInformation 0 0 0 []

data PoolRepairStatus = PoolRepairStatus
  { prsType :: PoolRepairType
  , prsRepairUUID :: UUID
  , prsPri :: Maybe PoolRepairInformation
  } deriving (Eq, Show, Generic, Typeable)

instance Binary PoolRepairStatus
instance Hashable PoolRepairStatus

-- | Vector of failed devices. We keep the order of failures because
-- mero should always send information about that to mero in the same
-- order.
newtype DiskFailureVector = DiskFailureVector [Disk]
  deriving (Eq, Show, Ord, Generic, Typeable, Hashable, Binary)

newtype LNid = LNid String
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

data HostHardwareInfo = HostHardwareInfo
       { hhMemorySize  :: Word64
       , hhCpuCount    :: Int
       , hhLNidAddress :: String
       }
   deriving (Eq, Show, Typeable, Generic)
instance Binary HostHardwareInfo
instance Hashable HostHardwareInfo

-- | Alias for process ID. In glibc @pid_t = int@.
newtype PID = PID Int
  deriving (Eq, Show, Typeable, Generic)

instance Binary PID
instance Hashable PID

-- | Process state. This is a generalisation of what might be reported to Mero.
data ProcessState =
    PSUnknown       -- ^ Process state is not known.
  | PSOffline       -- ^ Process is stopped.
  | PSStarting      -- ^ Process is starting but we have not confirmed started.
  | PSOnline        -- ^ Process is online.
  | PSStopping      -- ^ Process is currently stopping.
  | PSFailed String -- ^ Process has failed, with reason given
  | PSInhibited ProcessState -- ^ Process state is masked by a higher level
                             --   failure.
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessState
instance Hashable ProcessState
instance ToJSON ProcessState
instance FromJSON ProcessState

prettyProcessState :: ProcessState -> String
prettyProcessState PSUnknown = "N/A"
prettyProcessState PSOffline = "offline"
prettyProcessState PSStarting = "starting"
prettyProcessState PSOnline   = "online"
prettyProcessState PSStopping = "stopping"
prettyProcessState (PSFailed reason) = "failed (" ++ reason ++ ")"
prettyProcessState (PSInhibited st) = "inhibited (" ++ prettyProcessState st ++ ")"


-- | Label to attach to a Mero process providing extra context about how
--   it should run.
data ProcessLabel =
    PLM0t1fs -- ^ Process lives as part of m0t1fs in kernel space
  | PLBootLevel BootLevel -- ^ Process boot level. Currently 0 = confd, 1 = other0
  | PLNoBoot  -- ^ Tag processes which should not boot.
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessLabel
instance Hashable ProcessLabel

-- | Process boot level.
-- Currently:
--   * 0 - confd
--   * 1 - other
newtype BootLevel = BootLevel Int
  deriving
    (Eq, Show, Typeable, Generic, Binary, Hashable, Ord, FromJSON, ToJSON)

data MeroClusterState =
    MeroClusterStopped -- ^ Cluster is not running.
  | MeroClusterStarting BootLevel -- ^ Cluster is currently starting on a concrete bootlevel.
  | MeroClusterStopping BootLevel -- ^ Cluster is currently stopping on a concrete bootlevel.
  | MeroClusterRunning -- ^ Cluster is running succesfully.
  | MeroClusterFailed -- ^ Cluster bootstrap has failed.
  deriving (Eq,Show, Typeable, Generic)
instance Binary MeroClusterState
instance Hashable MeroClusterState
instance ToJSON MeroClusterState
instance FromJSON MeroClusterState

prettyStatus :: MeroClusterState -> String
prettyStatus MeroClusterStopped = "stopped"
prettyStatus (MeroClusterStarting (BootLevel i)) = "starting (bootlevel " ++ show i ++ ")"
prettyStatus (MeroClusterStopping (BootLevel i)) = "stopping (bootlevel " ++ show i ++ ")"
prettyStatus MeroClusterRunning = "running"
prettyStatus MeroClusterFailed = "failed"

instance Ord MeroClusterState where
   compare = compare `on` toInt where
     toInt MeroClusterRunning = maxBound
     toInt (MeroClusterStarting (BootLevel i)) = 1+i
     toInt MeroClusterStopped     = 0
     toInt (MeroClusterStopping (BootLevel i)) = -1-i
     toInt MeroClusterFailed = minBound


newtype ConfUpdateVersion = ConfUpdateVersion Word64
  deriving (Eq, Show, Typeable, Generic)

instance Binary ConfUpdateVersion
instance Hashable ConfUpdateVersion


-- | Process property, that shows that process was already bootstrapped,
-- and no mkfs is needed.
data ProcessBootstrapped = ProcessBootstrapped
  deriving (Eq, Show, Typeable, Generic)

instance Binary ProcessBootstrapped
instance Hashable ProcessBootstrapped

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(mkDicts
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus, ''LNid
  , ''HostHardwareInfo, ''ProcessLabel, ''ConfUpdateVersion
  , ''MeroClusterState, ''ProcessBootstrapped
  , ''ProcessState, ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Root)
  , (''R.Cluster, ''R.Has, ''MeroClusterState)
  , (''R.Cluster, ''R.Has, ''PVerCounter)
  , (''Root, ''IsParentOf, ''Profile)
  , (''R.Cluster, ''R.Has, ''Profile)
  , (''R.Cluster, ''R.Has, ''ConfUpdateVersion)
  , (''Controller, ''At, ''R.Host)
  , (''Rack, ''At, ''R.Rack)
  , (''Enclosure, ''At, ''R.Enclosure)
  , (''Disk, ''At, ''R.StorageDevice)
    -- Parent/child relationships between conf entities
  , (''Profile, ''IsParentOf, ''Filesystem)
  , (''Filesystem, ''IsParentOf, ''Node)
  , (''Filesystem, ''IsParentOf, ''Rack)
  , (''Filesystem, ''IsParentOf, ''Pool)
  , (''Node, ''IsParentOf, ''Process)
  , (''Process, ''IsParentOf, ''Service)
  , (''Service, ''IsParentOf, ''SDev)
  , (''Rack, ''IsParentOf, ''Enclosure)
  , (''Enclosure, ''IsParentOf, ''Controller)
  , (''Controller, ''IsParentOf, ''Disk)
  , (''PVer, ''IsParentOf, ''RackV)
  , (''RackV, ''IsParentOf, ''EnclosureV)
  , (''EnclosureV, ''IsParentOf, ''ControllerV)
  , (''ControllerV, ''IsParentOf, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Pool, ''IsRealOf, ''PVer)
  , (''Rack, ''IsRealOf, ''RackV)
  , (''Enclosure, ''IsRealOf, ''EnclosureV)
  , (''Controller, ''IsRealOf, ''ControllerV)
  , (''Disk, ''IsRealOf, ''DiskV)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, ''IsOnHardware, ''Disk)
  , (''Node, ''IsOnHardware, ''Controller)
    -- Other things!
  , (''R.Cluster, ''R.Has, ''FidSeq)
  , (''R.Cluster, ''R.Has, ''CI.M0Globals)
  , (''Pool, ''R.Has, ''PoolRepairStatus)
  , (''Pool, ''R.Has, ''DiskFailureVector)
  , (''R.Host, ''R.Has, ''LNid)
  , (''R.Host, ''R.Runs, ''Node)
  , (''Process, ''R.Has, ''ProcessLabel)
  , (''Process, ''R.Has, ''PID)
  , (''Process, ''R.Is, ''ProcessBootstrapped)
  , (''Process, ''R.Is, ''ProcessState)
  , (''Service, ''R.Is, ''ServiceState)
  , (''SDev, ''R.Is, ''SDevState)
  ]
  )

$(mkResRel
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus, ''LNid
  , ''HostHardwareInfo, ''ProcessLabel, ''ConfUpdateVersion
  , ''MeroClusterState, ''ProcessBootstrapped
  , ''ProcessState, ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Root)
  , (''R.Cluster, ''R.Has, ''MeroClusterState)
  , (''R.Cluster, ''R.Has, ''PVerCounter)
  , (''Root, ''IsParentOf, ''Profile)
  , (''R.Cluster, ''R.Has, ''Profile)
  , (''R.Cluster, ''R.Has, ''ConfUpdateVersion)
  , (''Controller, ''At, ''R.Host)
  , (''Rack, ''At, ''R.Rack)
  , (''Enclosure, ''At, ''R.Enclosure)
  , (''Disk, ''At, ''R.StorageDevice)
    -- Parent/child relationships between conf entities
  , (''Profile, ''IsParentOf, ''Filesystem)
  , (''Filesystem, ''IsParentOf, ''Node)
  , (''Filesystem, ''IsParentOf, ''Rack)
  , (''Filesystem, ''IsParentOf, ''Pool)
  , (''Node, ''IsParentOf, ''Process)
  , (''Process, ''IsParentOf, ''Service)
  , (''Service, ''IsParentOf, ''SDev)
  , (''Rack, ''IsParentOf, ''Enclosure)
  , (''Enclosure, ''IsParentOf, ''Controller)
  , (''Controller, ''IsParentOf, ''Disk)
  , (''PVer, ''IsParentOf, ''RackV)
  , (''RackV, ''IsParentOf, ''EnclosureV)
  , (''EnclosureV, ''IsParentOf, ''ControllerV)
  , (''ControllerV, ''IsParentOf, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Pool, ''IsRealOf, ''PVer)
  , (''Rack, ''IsRealOf, ''RackV)
  , (''Enclosure, ''IsRealOf, ''EnclosureV)
  , (''Controller, ''IsRealOf, ''ControllerV)
  , (''Disk, ''IsRealOf, ''DiskV)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, ''IsOnHardware, ''Disk)
  , (''Node, ''IsOnHardware, ''Controller)
    -- Other things!
  , (''R.Cluster, ''R.Has, ''FidSeq)
  , (''R.Cluster, ''R.Has, ''CI.M0Globals)
  , (''Pool, ''R.Has, ''PoolRepairStatus)
  , (''Pool, ''R.Has, ''DiskFailureVector)
  , (''R.Host, ''R.Has, ''LNid)
  , (''R.Host, ''R.Runs, ''Node)
  , (''Process, ''R.Has, ''ProcessLabel)
  , (''Process, ''R.Has, ''PID)
  , (''Process, ''R.Is, ''ProcessBootstrapped)
  , (''Process, ''R.Is, ''ProcessState)
  , (''Service, ''R.Is, ''ServiceState)
  , (''SDev, ''R.Is, ''SDevState)
  ]
  []
  )

-- | Get all 'M0.Service' running on the 'Cluster', starting at
-- 'M0.Profile's.
getM0Services :: G.Graph -> [Service]
getM0Services g =
  [ sv | p <- getM0Processes g
       , sv <- G.connectedTo p IsParentOf g
  ]

-- | Get all 'Process' running on the 'Cluster', starting at 'Profile's.
getM0Processes :: G.Graph -> [Process]
getM0Processes g =
  [ p | (prof :: Profile) <- G.connectedTo R.Cluster R.Has g
       , (fs :: Filesystem) <- G.connectedTo prof IsParentOf g
       , (node :: Node) <- G.connectedTo fs IsParentOf g
       , p <- G.connectedTo node IsParentOf g
  ]

-- | Lookup a configuration object in the resource graph.
lookupConfObjByFid :: forall a. (G.Resource a, ConfObj a)
                     => Fid
                     -> G.Graph
                     -> Maybe a
lookupConfObjByFid f =
    listToMaybe
  . filter ((== f) . fid)
  . G.getResourcesOfType

-- | Lookup 'Node' associated with the given 'R.Node'.
m0nodeToNode :: Node -> G.Graph -> Maybe R.Node
m0nodeToNode m0node rg = listToMaybe
  [ node | (h :: R.Host) <- G.connectedFrom R.Runs m0node rg
         , node <- G.connectedTo h R.Runs rg ]
