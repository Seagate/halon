{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
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
import Mero.Spiel (FSStats)

import Data.Aeson
import Data.Aeson.Types (typeMismatch)
import Data.Binary (Binary(..))
import Data.Bits
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.Hashable (Hashable(..))
import Data.Int (Int64)
import Data.Ord (comparing)
import Data.Proxy (Proxy(..))
import Data.Scientific
import Data.Typeable (Typeable)
import qualified Data.Vector as V
import Data.Word ( Word32, Word64 )
import GHC.Generics (Generic)
import qualified "distributed-process-scheduler" System.Clock as C
import Data.Maybe (listToMaybe)
import Data.UUID (UUID)
import qualified Data.UUID as UUID

import qualified HA.ResourceGraph as G
import HA.SafeCopy hiding (Profile)
--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | Fid type mask
typMask :: Word64
typMask = 0x00ffffffffffffff

-- | Fid generation sequence number
newtype FidSeq = FidSeq Word64
  deriving (Eq, Generic, Hashable, Show, Typeable)
deriveSafeCopy 0 'base ''FidSeq

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
fidIsType p fid' = fidToFidType fid' == confToFidType p

-- | Like 'fidType' but shifted which allows for a much easier
-- comparison of proxy fid types with raw 'Fid's.
confToFidType :: ConfObj a => Proxy a -> Word64
confToFidType p = fidType p `shiftL` (64 - 8)

-- | Take a raw 'Fid' and extract the the type.
-- Useful when the container may have been poluted with extra
-- information such as through 'fidInit'.
fidToFidType :: Fid -> Word64
fidToFidType (Fid ctr _) = ctr .&. complement typMask


data AnyConfObj = forall a. ConfObj a => AnyConfObj a
  deriving (Typeable)

instance Eq AnyConfObj where
  AnyConfObj obj == AnyConfObj obj' = fid obj == fid obj'

data SpielAddress = SpielAddress {
    sa_confds_fid :: [Fid]
  , sa_confds_ep :: [String]
  , sa_rm_fid :: Fid
  , sa_rm_ep :: String
  , sa_quorum :: Int -- ^ number of the confd required for quorum.
}  deriving (Eq, Generic, Show, Typeable)

instance Binary SpielAddress
instance Hashable SpielAddress

data SyncToConfd =
      SyncToConfdServersInRG
    | SyncDumpToBS ProcessId
  deriving (Eq, Generic, Show, Typeable)

instance Hashable SyncToConfd
deriveSafeCopy 0 'base ''SyncToConfd

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

instance Hashable At
deriveSafeCopy 0 'base ''At

-- | Relationship between parent and child entities in confd
--   Directed from parent to child (e.g. profile IsParentOf filesystem)
data IsParentOf = IsParentOf
   deriving (Eq, Generic, Show, Typeable)

instance Hashable IsParentOf
deriveSafeCopy 0 'base ''IsParentOf

-- | Relationship between virtual and real entities in confd.
--   Directed from real to virtual (e.g. pool IsRealOf pver)
data IsRealOf = IsRealOf
   deriving (Eq, Generic, Show, Typeable)

instance Hashable IsRealOf
deriveSafeCopy 0 'base ''IsRealOf

-- | Relationship between conceptual and hardware entities in confd
--   Directed from sdev to disk (e.g. sdev IsOnHardware disk)
--   Directed from node to controller (e.g. node IsOnHardware controller)
data IsOnHardware = IsOnHardware
   deriving (Eq, Generic, Show, Typeable)

instance Hashable IsOnHardware
deriveSafeCopy 0 'base ''IsOnHardware

newtype Root = Root Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Root where
   fidType _ = fromIntegral . ord $ 't'
   fid (Root f) = f
deriveSafeCopy 0 'base ''Root

newtype Profile = Profile Fid
  deriving (Eq, Generic, Hashable, Show, Typeable, FromJSON, ToJSON)

instance ConfObj Profile where
  fidType _ = fromIntegral . ord $ 'p'
  fid (Profile f) = f
deriveSafeCopy 0 'base ''Profile

data Filesystem = Filesystem {
    f_fid :: Fid
  , f_mdpool_fid :: Fid -- ^ Fid of filesystem metadata pool
} deriving (Eq, Generic, Show, Typeable)

instance Hashable Filesystem
instance ToJSON Filesystem
instance FromJSON Filesystem

instance ConfObj Filesystem where
  fidType _ = fromIntegral . ord $ 'f'
  fid = f_fid
deriveSafeCopy 0 'base ''Filesystem

newtype Node = Node Fid
  deriving (Eq, Generic, Hashable, Show, Typeable, Ord)

instance ConfObj Node where
  fidType _ = fromIntegral . ord $ 'n'
  fid (Node f) = f

instance FromJSON Node
instance ToJSON   Node
deriveSafeCopy 0 'base ''Node

-- | Node state. This is a generalization of what might be reported to Mero.
data NodeState
  = NSUnknown             -- ^ Node state is not known.
  | NSOffline             -- ^ Node is stopped, gracefully.
  | NSFailedUnrecoverable -- ^ Node is failed
  | NSFailed              -- ^ Node is failed, possibly can be recovered.
  | NSOnline              -- ^ Node is online.
  deriving (Eq, Show, Typeable, Generic, Read, Ord)

instance Hashable NodeState
instance ToJSON NodeState
instance FromJSON NodeState
deriveSafeCopy 0 'base ''NodeState

prettyNodeState :: NodeState -> String
prettyNodeState NSUnknown = "N/A"
prettyNodeState NSOffline = "offline"
prettyNodeState NSFailed  = "failed(recoverable)"
prettyNodeState NSFailedUnrecoverable  = "failed(unrecoverable)"
prettyNodeState NSOnline = "online"

displayNodeState :: NodeState -> (String, Maybe String)
displayNodeState xs@NSFailed = ("failed", Just $ prettyNodeState xs)
displayNodeState xs@NSFailedUnrecoverable = ("failed", Just $ prettyNodeState xs)
displayNodeState xs = (prettyNodeState xs, Nothing)

newtype Rack = Rack Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Rack where
  fidType _ = fromIntegral . ord $ 'a'
  fid (Rack f) = f
deriveSafeCopy 0 'base ''Rack

newtype Pool = Pool Fid
  deriving
    (Eq, Generic, Hashable, Show, Typeable, Ord, FromJSON, ToJSON)

instance ConfObj Pool where
  fidType _ = fromIntegral . ord $ 'o'
  fid (Pool f) = f
deriveSafeCopy 0 'base ''Pool

data Process = Process {
    r_fid :: Fid
  , r_mem_as :: Word64
  , r_mem_rss :: Word64
  , r_mem_stack :: Word64
  , r_mem_memlock :: Word64
  , r_cores :: Bitmap
  , r_endpoint :: String
} deriving (Eq, Generic, Show, Typeable)

instance Hashable Process
instance ToJSON Process
instance FromJSON Process
instance ToJSON Bitmap
instance FromJSON Bitmap
instance ConfObj Process where
  fidType _ = fromIntegral . ord $ 'r'
  fid = r_fid
instance Ord Process where
  compare = comparing r_fid
deriveSafeCopy 0 'base ''Process

data Service = Service {
    s_fid :: Fid
  , s_type :: ServiceType -- ^ e.g. ioservice, haservice
  , s_endpoints :: [String]
  , s_params :: ServiceParams
} deriving (Eq, Generic, Show, Typeable)

instance Ord Service where
  compare = comparing s_fid

instance Hashable Service
instance ToJSON Service
instance FromJSON Service
instance ConfObj Service where
  fidType _ = fromIntegral . ord $ 's'
  fid = s_fid
deriveSafeCopy 0 'base ''Service

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
  deriving (Eq, Show, Typeable, Generic, Read, Ord)
instance Hashable ServiceState
instance ToJSON ServiceState
instance FromJSON ServiceState
deriveSafeCopy 0 'base ''ServiceState

prettyServiceState :: ServiceState -> String
prettyServiceState SSUnknown = "N/A"
prettyServiceState SSOffline = "offline"
prettyServiceState SSStarting = "starting"
prettyServiceState SSOnline   = "online"
prettyServiceState SSStopping = "stopping"
prettyServiceState SSFailed   = "failed"
prettyServiceState (SSInhibited st) = "inhibited (" ++ prettyServiceState st ++ ")"

displayServiceState :: ServiceState -> (String, Maybe String)
displayServiceState s@SSInhibited{} = ("inhibited", Just $ prettyServiceState s)
displayServiceState s = (prettyServiceState s, Nothing)

data SDev = SDev {
    d_fid :: Fid
  , d_idx :: Word32 -- ^ Index of device in pool
  , d_size :: Word64 -- ^ Size in mb
  , d_bsize :: Word32 -- ^ Block size in mb
  , d_path :: String -- ^ Path to logical device
} deriving (Eq, Generic, Show, Typeable, Ord)
deriveSafeCopy 0 'base ''SDev

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
  | SDSInhibited SDevState -- Failure is inhibited by a higher level failure.
  | SDSTransient SDevState -- Transient failure, and state before said
                           -- transient failure.
  deriving (Eq, Show, Typeable, Generic, Read, Ord)

instance Hashable SDevState
instance ToJSON SDevState
instance FromJSON SDevState
deriveSafeCopy 0 'base ''SDevState

prettySDevState :: SDevState -> String
prettySDevState SDSUnknown = "Unknown"
prettySDevState SDSOnline = "Online"
prettySDevState SDSFailed = "Failed"
prettySDevState SDSRepairing = "Repairing"
prettySDevState SDSRepaired = "Repaired"
prettySDevState SDSRebalancing = "Rebalancing"
prettySDevState (SDSInhibited x) = "Inhibited (" ++ prettySDevState x ++ ")"
prettySDevState (SDSTransient x) = "Transient failure (" ++ prettySDevState x ++ ")"

displaySDevState :: SDevState -> (String, Maybe String)
displaySDevState s@SDSInhibited{} = ("inhibited", Just $ prettySDevState s)
displaySDevState s@SDSTransient{} = ("transient", Just $ prettySDevState s)
displaySDevState s = (prettySDevState s, Nothing)

-- | Transiently fail a drive in an existing state. Most of the time
--   this will result in @x@ becoming @SDSTransient x@, but with exceptions
--   where the device is failed or already transient.
sdsFailTransient :: SDevState -> SDevState
sdsFailTransient SDSFailed = SDSFailed
sdsFailTransient SDSRepairing = SDSRepairing
sdsFailTransient SDSRepaired = SDSRepaired
sdsFailTransient s@(SDSTransient _) = s
sdsFailTransient (SDSInhibited x) = SDSInhibited $ sdsFailTransient x
sdsFailTransient x = SDSTransient x

-- | Update state following recovery from a transient failure. In general
--   this should restore the previous state.
sdsRecoverTransient :: SDevState -> SDevState
sdsRecoverTransient (SDSTransient x) = x
sdsRecoverTransient (SDSInhibited x) = SDSInhibited $ sdsRecoverTransient x
sdsRecoverTransient y = y

-- | Permanently fail an SDev. Most of the time this will switch
--   a device to @SDSFailed@, unless it is already repairing or
--   repaired. In cases where repair fails the state should be
--   set back to @SDSFailed@ through a direct transition rather than
--   using this.
sdsFailFailed :: SDevState -> SDevState
sdsFailFailed SDSRepairing = SDSRepairing
sdsFailFailed SDSRepaired = SDSRepaired
sdsFailFailed _ = SDSFailed

newtype Enclosure = Enclosure Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Enclosure where
  fidType _ = fromIntegral . ord $ 'e'
  fid (Enclosure f) = f
deriveSafeCopy 0 'base ''Enclosure

-- | A controller represents an entity which allows access to a number of
--   disks. It will typically be hosted on a node.
newtype Controller = Controller Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ToJSON Controller
instance FromJSON Controller
deriveSafeCopy 0 'base ''Controller

-- | Controller state type. Note that:
--   - A controller cannot be meaningfully turned 'off', so there is no
--     offline state.
--   - A controller has no persistent identity of its own, so there is no
--     permanent failure state. A controller which is completely broken and
--     replaced will appear identical from Halon's perspective.
data ControllerState
  = CSUnknown -- ^ We do not know the state of the controller.
  | CSOnline -- ^ Controller is fine.
  | CSTransient -- ^ Controller is experiencing a failure.
  deriving (Eq, Show, Typeable, Generic, Read)
deriveSafeCopy 0 'base ''ControllerState

instance Hashable ControllerState

instance ConfObj Controller where
  fidType _ = fromIntegral . ord $ 'c'
  fid (Controller f) = f

newtype Disk = Disk Fid
  deriving (Eq, Generic, Hashable, Show, Typeable, Ord)
deriveSafeCopy 0 'base ''Disk

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

instance Hashable PVerType
deriveSafeCopy 0 'base ''PVerType

data PVer = PVer {
    v_fid :: Fid
  , v_type :: PVerType
} deriving (Eq, Generic, Show, Typeable)

instance Hashable PVer
deriveSafeCopy 0 'base ''PVer

newtype PVerCounter = PVerCounter Word32
  deriving (Eq, Generic, Show, Typeable, Ord, Hashable)

instance ConfObj PVer where
  fidType _ = fromIntegral . ord $ 'v'
  fid = v_fid
deriveSafeCopy 0 'base ''PVerCounter

newtype RackV = RackV Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ConfObj RackV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (RackV f) = f
deriveSafeCopy 0 'base ''RackV

newtype EnclosureV = EnclosureV Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ConfObj EnclosureV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (EnclosureV f) = f
deriveSafeCopy 0 'base ''EnclosureV

newtype ControllerV = ControllerV Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ConfObj ControllerV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (ControllerV f) = f
deriveSafeCopy 0 'base ''ControllerV

newtype DiskV = DiskV Fid
  deriving (Eq, Generic, Hashable, Show, Typeable)

instance ConfObj DiskV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (DiskV f) = f
deriveSafeCopy 0 'base ''DiskV

-- | Wrapper for 'C.TimeSpec' providing 'Binary' and 'Hashable'
-- instances.
--
-- Normally you should use 'mkTimeSpec' to create these.
--
-- TODO: Move this somewhere else
newtype TimeSpec = TimeSpec { _unTimeSpec :: C.TimeSpec }
  deriving (Eq, Num, Ord, Read, Show, Generic, Typeable)

deriveSafeCopy 0 'base ''TimeSpec

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

-- | Get current time using a 'C.Monotonic' 'C.Clock'.
getTime :: IO TimeSpec
getTime = TimeSpec <$> C.getTime C.Monotonic

-- | Get number of seconds that have elapsed since the given 'TimeSpec'.
secondsSince :: TimeSpec -> IO Int
secondsSince oldSpec = do
  ct <- getTime
  return . timeSpecToSeconds $ ct - oldSpec

-- | Classifies 'PoolRepairInformation'. By the time we get
-- information back from mero about the status of the pool, we no
-- longer know whether we have been recovering from failure or whether
-- we're just rebalancing.
--
-- We use this as an indicator. The underlying assumption is that a
-- repair and rebalance will never happen at the same time.
-- TODO s/Failure/Repair
data PoolRepairType = Failure | Rebalance
  deriving (Eq, Show, Ord, Generic, Typeable)

deriveSafeCopy 0 'base ''PoolRepairType
instance Hashable PoolRepairType
instance ToJSON PoolRepairType
instance FromJSON PoolRepairType

-- | Information attached to 'PoolRepairStatus'.
data PoolRepairInformation = PoolRepairInformation
  { priOnlineNotifications :: Int
  , priTimeOfFirstCompletion :: TimeSpec
  , priTimeLastHourlyRan :: TimeSpec
  , priStateUpdates      :: [(SDev, Int)]
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable PoolRepairInformation
instance ToJSON PoolRepairInformation
instance FromJSON PoolRepairInformation
deriveSafeCopy 0 'base ''PoolRepairInformation

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
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable PoolRepairStatus
instance ToJSON PoolRepairStatus where
  toJSON (PoolRepairStatus t u p) = object
    [ "type" .= t
    , "uuid" .= UUID.toText u
    , "info" .= p
    ]
instance FromJSON PoolRepairStatus where
  parseJSON = withObject "PoolRepairStatus" $ \v ->
    PoolRepairStatus <$> v .: "type"
                     <*> (maybe (fail "can't parse uuid") return . UUID.fromText =<< (v .: "uuid"))
                     <*> v .: "info"

-- instance FromJSON PoolRepairStatus
deriveSafeCopy 0 'base ''PoolRepairStatus

-- | Vector of failed devices. We keep the order of failures because
-- mero should always send information about that to mero in the same
-- order.
newtype DiskFailureVector = DiskFailureVector [Disk]
  deriving (Eq, Show, Ord, Generic, Typeable, Hashable)
deriveSafeCopy 0 'base ''DiskFailureVector

newtype LNid = LNid String
  deriving (Eq, Generic, Hashable, Show, Typeable)
deriveSafeCopy 0 'base ''LNid

data HostHardwareInfo = HostHardwareInfo
       { hhMemorySize  :: Word64
       , hhCpuCount    :: Int
       , hhLNidAddress :: String
       }
   deriving (Eq, Show, Typeable, Generic)
instance Hashable HostHardwareInfo
deriveSafeCopy 0 'base ''HostHardwareInfo

-- | Alias for process ID. In glibc @pid_t = int@.
newtype PID = PID Int
  deriving (Eq, Show, Typeable, Generic)

instance Hashable PID
deriveSafeCopy 0 'base ''PID

-- | Process state. This is a generalisation of what might be reported to Mero.
data ProcessState =
    PSUnknown       -- ^ Process state is not known.
  | PSOffline       -- ^ Process is stopped.
  | PSStarting      -- ^ Process is starting but we have not confirmed started.
  | PSOnline        -- ^ Process is online.
  | PSQuiescing     -- ^ Process is online, but should reject any further requests.
  | PSStopping      -- ^ Process is currently stopping.
  | PSFailed String -- ^ Process has failed, with reason given
  | PSInhibited ProcessState -- ^ Process state is masked by a higher level
                             --   failure.
  deriving (Eq, Show, Typeable, Generic, Read, Ord)
instance Hashable ProcessState
instance ToJSON ProcessState
instance FromJSON ProcessState
deriveSafeCopy 0 'base ''ProcessState

prettyProcessState :: ProcessState -> String
prettyProcessState PSUnknown = "N/A"
prettyProcessState PSOffline = "offline"
prettyProcessState PSStarting = "starting"
prettyProcessState PSOnline   = "online"
prettyProcessState PSQuiescing   = "quiescing"
prettyProcessState PSStopping = "stopping"
prettyProcessState (PSFailed reason) = "failed (" ++ reason ++ ")"
prettyProcessState (PSInhibited st) = "inhibited (" ++ prettyProcessState st ++ ")"

displayProcessState :: ProcessState -> (String, Maybe String)
displayProcessState s@PSFailed{} = ("failed", Just $ prettyProcessState s)
displayProcessState s@PSInhibited{} = ("inhibited", Just $ prettyProcessState s)
displayProcessState s = ( prettyProcessState s, Nothing)

-- | Label to attach to a Mero process providing extra context about how
--   it should run.
data ProcessLabel =
    PLM0t1fs -- ^ Process lives as part of m0t1fs in kernel space
  | PLBootLevel BootLevel -- ^ Process boot level. Currently 0 = confd, 1 = other0
  | PLNoBoot  -- ^ Tag processes which should not boot.
  deriving (Eq, Show, Typeable, Generic)
instance Hashable ProcessLabel

-- | Process boot level.
--   This is used both to tag processes (to indicate when they should start/stop)
--   and to tag the cluster (to indicate which processes it's valid to try to
--   start/stop).
--   Given a cluster run level of x, it is valid to start a process with a
--   boot level of <= x. So at level 0 we may start confd processes, at level
--   1 we may start IOS etc as well as confd processes.
-- Currently:
--   * 0 - confd
--   * 1 - other
--   * 2 - clients
newtype BootLevel = BootLevel { unBootLevel :: Int }
  deriving
    (Eq, Show, Typeable, Generic, Hashable, Ord, FromJSON, ToJSON)
deriveSafeCopy 0 'base ''BootLevel
deriveSafeCopy 0 'base ''ProcessLabel

-- | Cluster disposition.
--   This represents the desired state for the cluster, which is used to
--   decide upon the correct behaviour to take in reaction to events.
data Disposition =
    ONLINE -- ^ Cluster should be online
  | OFFLINE -- ^ Cluster should be offline (e.g. for maintenance)
  deriving (Eq, Show, Typeable, Generic)

instance Hashable Disposition
instance ToJSON Disposition
instance FromJSON Disposition
deriveSafeCopy 0 'base ''Disposition

-- | Marker to tag the cluster run level
data RunLevel = RunLevel
  deriving (Eq, Show, Generic, Typeable)

instance Hashable RunLevel
deriveSafeCopy 0 'base ''RunLevel

-- | Marker to tag the cluster stop level
data StopLevel = StopLevel
  deriving (Eq, Show, Generic, Typeable)

instance Hashable StopLevel
deriveSafeCopy 0 'base ''StopLevel

-- | Cluster state.
--   We do not store this cluster state in the graph, but it's a useful
--   aggregation for sending to clients.
data MeroClusterState = MeroClusterState {
    _mcs_disposition :: Disposition
  , _mcs_runlevel :: BootLevel
  , _mcs_stoplevel :: BootLevel
} deriving (Eq, Show, Typeable, Generic)

instance Binary MeroClusterState
instance FromJSON MeroClusterState
instance ToJSON MeroClusterState

prettyStatus :: MeroClusterState -> String
prettyStatus MeroClusterState{..} = unlines [
    "Disposition: " ++ (show _mcs_disposition)
  , "Current run level: " ++ (show . unBootLevel $ _mcs_runlevel)
  , "Current stop level: " ++ (show . unBootLevel $ _mcs_stoplevel)
  ]

-- | Information about the update state of the conf database. Holds
-- version number of the current data and its hash. When we want to
-- potentially update the database, we don't want to recommit and
-- increase the version number when no actual changes have happened:
-- we can just check against the hash if we actually have some changes
-- to commit.
data ConfUpdateVersion = ConfUpdateVersion Word64 (Maybe Int)
  deriving (Eq, Show, Typeable, Generic)

instance Hashable ConfUpdateVersion
deriveSafeCopy 0 'base ''ConfUpdateVersion


-- | Process property, that shows that process was already bootstrapped,
-- and no mkfs is needed.
data ProcessBootstrapped = ProcessBootstrapped
  deriving (Eq, Show, Typeable, Generic)

instance Hashable ProcessBootstrapped
deriveSafeCopy 0 'base ''ProcessBootstrapped

-- | Filesystem statistics
data FilesystemStats = FilesystemStats {
    _fs_fetched_on :: TimeSpec
  , _fs_stats :: FSStats
} deriving (Eq, Show, Typeable, Generic)

instance Hashable FilesystemStats
instance ToJSON FilesystemStats
instance FromJSON FilesystemStats

deriveSafeCopy 0 'base ''FSStats
deriveSafeCopy 0 'base ''FilesystemStats
--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(mkDicts
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus, ''LNid
  , ''HostHardwareInfo, ''ProcessLabel, ''ConfUpdateVersion
  , ''Disposition, ''ProcessBootstrapped
  , ''ProcessState, ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter, ''NodeState, ''ControllerState
  , ''BootLevel, ''RunLevel, ''StopLevel, ''FilesystemStats
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Root)
  , (''R.Cluster, ''R.Has, ''Disposition)
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
  , (''R.Cluster, ''RunLevel, ''BootLevel)
  , (''R.Cluster, ''StopLevel, ''BootLevel)
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
  , (''Node,    ''R.Is, ''NodeState)
  , (''Controller,    ''R.Is, ''ControllerState)
  , (''Filesystem, ''R.Has, ''FilesystemStats)
  ]
  )

$(mkResRel
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus, ''LNid
  , ''HostHardwareInfo, ''ProcessLabel, ''ConfUpdateVersion
  , ''Disposition, ''ProcessBootstrapped
  , ''ProcessState, ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter, ''NodeState, ''ControllerState
  , ''BootLevel, ''RunLevel, ''StopLevel, ''FilesystemStats
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''Root)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''Disposition)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''PVerCounter)
  , (''Root, AtMostOne, ''IsParentOf, AtMostOne, ''Profile)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''Profile)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''ConfUpdateVersion)
  , (''Controller, AtMostOne, ''At, AtMostOne, ''R.Host)
  , (''Rack, AtMostOne, ''At, AtMostOne, ''R.Rack)
  , (''Enclosure, AtMostOne, ''At, AtMostOne, ''R.Enclosure)
  , (''Disk, AtMostOne, ''At, AtMostOne, ''R.StorageDevice)
    -- Parent/child relationships between conf entities
  , (''Profile, AtMostOne, ''IsParentOf, Unbounded, ''Filesystem)
  , (''Filesystem, AtMostOne, ''IsParentOf, Unbounded, ''Node)
  , (''Filesystem, AtMostOne, ''IsParentOf, Unbounded, ''Rack)
  , (''Filesystem, AtMostOne, ''IsParentOf, Unbounded, ''Pool)
  , (''Node, AtMostOne, ''IsParentOf, Unbounded, ''Process)
  , (''Process, AtMostOne, ''IsParentOf, Unbounded, ''Service)
  , (''Service, AtMostOne, ''IsParentOf, Unbounded, ''SDev)
  , (''Rack, AtMostOne, ''IsParentOf, Unbounded, ''Enclosure)
  , (''Enclosure, AtMostOne, ''IsParentOf, Unbounded, ''Controller)
  , (''Controller, AtMostOne, ''IsParentOf, Unbounded, ''Disk)
  , (''PVer, AtMostOne, ''IsParentOf, Unbounded, ''RackV)
  , (''RackV, AtMostOne, ''IsParentOf, Unbounded, ''EnclosureV)
  , (''EnclosureV, AtMostOne, ''IsParentOf, Unbounded, ''ControllerV)
  , (''ControllerV, AtMostOne, ''IsParentOf, Unbounded, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Pool, AtMostOne, ''IsRealOf, Unbounded, ''PVer)
  , (''Rack, AtMostOne, ''IsRealOf, Unbounded, ''RackV)
  , (''Enclosure, AtMostOne, ''IsRealOf, Unbounded, ''EnclosureV)
  , (''Controller, AtMostOne, ''IsRealOf, Unbounded, ''ControllerV)
  , (''Disk, AtMostOne, ''IsRealOf, Unbounded, ''DiskV)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, AtMostOne, ''IsOnHardware, AtMostOne, ''Disk)
  , (''Node, AtMostOne, ''IsOnHardware, AtMostOne, ''Controller)
    -- Other things!
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''FidSeq)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''CI.M0Globals)
  , (''R.Cluster, AtMostOne, ''RunLevel, AtMostOne, ''BootLevel)
  , (''R.Cluster, AtMostOne, ''StopLevel, AtMostOne, ''BootLevel)
  , (''Pool, AtMostOne, ''R.Has, AtMostOne, ''PoolRepairStatus)
  , (''Pool, AtMostOne, ''R.Has, AtMostOne, ''DiskFailureVector)
  , (''R.Host, AtMostOne, ''R.Has, Unbounded, ''LNid)
  , (''R.Host, AtMostOne, ''R.Runs, Unbounded, ''Node)
  , (''Process, Unbounded, ''R.Has, Unbounded, ''ProcessLabel)
  , (''Process, Unbounded, ''R.Has, AtMostOne, ''PID)
  , (''Process, Unbounded, ''R.Is, AtMostOne, ''ProcessBootstrapped)
  , (''Process, Unbounded, ''R.Is, AtMostOne, ''ProcessState)
  , (''Service, Unbounded, ''R.Is, AtMostOne, ''ServiceState)
  , (''SDev, Unbounded, ''R.Is, AtMostOne, ''SDevState)
  , (''Node, Unbounded,    ''R.Is, AtMostOne, ''NodeState)
  , (''Controller, Unbounded,    ''R.Is, AtMostOne, ''ControllerState)
  , (''Filesystem, Unbounded, ''R.Has, AtMostOne, ''FilesystemStats)
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
  [ p | Just (prof :: Profile) <- [G.connectedTo R.Cluster R.Has g]
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
  [ node | Just (h :: R.Host) <- [G.connectedFrom R.Runs m0node rg]
         , node <- G.connectedTo h R.Runs rg ]
