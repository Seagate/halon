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
import Data.Binary (Binary(..))
import Data.Bits
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.Hashable (Hashable(..))
import Data.Int (Int64)
import Data.Proxy (Proxy(..))
import Data.Typeable (Typeable)
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
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Profile where
  fidType _ = fromIntegral . ord $ 'p'
  fid (Profile f) = f

data Filesystem = Filesystem {
    f_fid :: Fid
  , f_mdpool_fid :: Fid -- ^ Fid of filesystem metadata pool
} deriving (Eq, Generic, Show, Typeable)

instance Binary Filesystem
instance Hashable Filesystem

instance ConfObj Filesystem where
  fidType _ = fromIntegral . ord $ 'f'
  fid = f_fid

newtype Node = Node Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Node where
  fidType _ = fromIntegral . ord $ 'n'
  fid (Node f) = f

newtype Rack = Rack Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Rack where
  fidType _ = fromIntegral . ord $ 'a'
  fid (Rack f) = f

newtype Pool = Pool Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable, Ord)

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
instance ConfObj Service where
  fidType _ = fromIntegral . ord $ 's'
  fid = s_fid

data SDev = SDev {
    d_fid :: Fid
  , d_idx :: Word32 -- ^ Index of device in pool
  , d_size :: Word64 -- ^ Size in mb
  , d_bsize :: Word32 -- ^ Block size in mb
  , d_path :: String -- ^ Path to logical device
} deriving (Eq, Generic, Show, Typeable, Ord)

instance Binary SDev
instance Hashable SDev
instance ConfObj SDev where
  fidType _ = fromIntegral . ord $ 'd'
  fid = d_fid

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
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Disk where
  fidType _ = fromIntegral . ord $ 'k'
  fid (Disk f) = f

data PVer = PVer {
    v_fid :: Fid
  , v_failures :: [Word32]
  , v_attrs :: PDClustAttr
} deriving (Eq, Generic, Show, Typeable)

instance Binary PVer
instance Hashable PVer

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

-- | Process state. This is a generalisation of what might be reported to Mero.
data ProcessState =
    PSUnknown -- ^ Process state is not known.
  | PSOffline -- ^ Process is stopped.
  | PSStarting -- ^ Process is starting but we have not confirmed started.
  | PSOnline
  | PSStopping
  | PSFailed String -- ^ Process has failed, with reason given
  | PSInhibited ProcessState -- ^ Process state is masked by a higher level
                             --   failure.
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessState
instance Hashable ProcessState

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
  deriving (Eq, Show, Typeable, Generic, Binary, Hashable, Ord)

data MeroClusterState =
    MeroClusterStopped -- ^ Cluster is not running.
  | MeroClusterStarting BootLevel -- ^ Cluster is currently starting on a concrete bootlevel.
  | MeroClusterStopping BootLevel -- ^ Cluster is currently stopping on a concrete bootlevel.
  | MeroClusterRunning -- ^ Cluster is running succesfully.
  | MeroClusterFailed -- ^ Cluster bootstrap has failed.
  deriving (Eq,Show, Typeable, Generic)
instance Binary MeroClusterState
instance Hashable MeroClusterState

prettyStatus :: MeroClusterState -> String
prettyStatus MeroClusterStopped = "stopped"
prettyStatus (MeroClusterStarting (BootLevel i)) = "starting (bootlevel " ++ show i ++ ")"
prettyStatus (MeroClusterStopping (BootLevel i)) = "stopping (bootlevel " ++ show i ++ ")"
prettyStatus MeroClusterRunning = "running"
prettyStatus MeroClusterFailed = "failed"

instance ToJSON MeroClusterState where
  toJSON = toJSON . prettyStatus

instance Ord MeroClusterState where
   compare MeroClusterRunning MeroClusterRunning = EQ
   compare MeroClusterRunning _ = GT
   compare (MeroClusterStarting i) (MeroClusterStarting j) = i `compare` j
   compare MeroClusterStarting{} _ = GT
   compare MeroClusterStopped MeroClusterStopped = EQ
   compare MeroClusterStopped _ = GT
   compare (MeroClusterStopping i) (MeroClusterStopping j) = j `compare` i -- !!!!!!
   compare a b = case compare b a of
                   GT -> LT
                   LT -> GT
                   EQ -> EQ

-- | Message sent when mero service fails to come up, failing bootstrap.
newtype BootstrapFailedNotification = BootstrapFailedNotification String
  deriving(Eq, Show, Typeable, Generic)
instance Binary BootstrapFailedNotification
instance Hashable BootstrapFailedNotification

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
  , ''ProcessState
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Root)
  , (''R.Cluster, ''R.Has, ''MeroClusterState)
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
  , (''R.Host, ''R.Has, ''LNid)
  , (''R.Host, ''R.Runs, ''Node)
  , (''Process, ''R.Has, ''ProcessLabel)
  , (''Process, ''R.Is, ''ProcessBootstrapped)
  , (''Process, ''R.Is, ''ProcessState)
  ]
  )

$(mkResRel
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus, ''LNid
  , ''HostHardwareInfo, ''ProcessLabel, ''ConfUpdateVersion
  , ''MeroClusterState, ''ProcessBootstrapped
  , ''ProcessState
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Root)
  , (''R.Cluster, ''R.Has, ''MeroClusterState)
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
  , (''R.Host, ''R.Has, ''LNid)
  , (''R.Host, ''R.Runs, ''Node)
  , (''Process, ''R.Has, ''ProcessLabel)
  , (''Process, ''R.Is, ''ProcessBootstrapped)
  , (''Process, ''R.Is, ''ProcessState)
  ]
  []
  )

-- | Get all 'M0.Service' running on the 'Cluster', starting at
-- 'M0.Profile's.
getM0Services :: G.Graph -> [Service]
getM0Services g =
  [ sv | (prof :: Profile) <- G.connectedTo R.Cluster R.Has g
       , (fs :: Filesystem) <- G.connectedTo prof IsParentOf g
       , (node :: Node) <- G.connectedTo fs IsParentOf g
       , (p :: Process) <- G.connectedTo node IsParentOf g
       , sv <- G.connectedTo p IsParentOf g
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
