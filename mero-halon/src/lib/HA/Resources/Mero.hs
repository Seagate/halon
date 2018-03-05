{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PackageImports             #-}
{-# LANGUAGE StrictData                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
-- For graph instances
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- |
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero specific resources in Halon.
-- Should be imported qualified:
--
-- @import qualified HA.Resources.Mero as M0@
module HA.Resources.Mero
  ( module HA.Resources.Mero
  , CI.M0Globals
  ) where

import           Control.Distributed.Process (ProcessId)
import           Data.Binary (Binary(..))
import           Data.Bits
import qualified Data.ByteString as BS
import           Data.Char (ord)
import           Data.Either (rights)
import           Data.Hashable (Hashable(..))
import           Data.Int (Int64)
import           Data.Maybe (listToMaybe)
import           Data.Ord (comparing)
import           Data.Proxy (Proxy(..))
import           Data.Scientific
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import           Data.UUID (UUID)
import qualified Data.Vector as V
import           Data.Word (Word32, Word64)
import           GHC.Generics (Generic)
import           HA.Aeson
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.TH
import           HA.SafeCopy hiding (Profile)
import           Mero.ConfC
  ( Bitmap
  , Fid(..)
  , PDClustAttr(..)
  , ServiceParams
  , ServiceType
  )
import           Mero.Lnet (Endpoint, readEndpoint)
import qualified Mero.Lnet as Lnet
import           Mero.Spiel (FSStats)
import qualified "distributed-process-scheduler" System.Clock as C

--------------------------------------------------------------------------------
-- Resources
--------------------------------------------------------------------------------

-- | Fid type mask
typMask :: Word64
typMask = 0x00ffffffffffffff

-- | Fid generation sequence number
newtype FidSeq = FidSeq Word64
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

storageIndex ''FidSeq "64e86424-83b3-49f6-91b9-47fa4597a98a"
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
  deriving Typeable

instance Eq AnyConfObj where
  AnyConfObj obj == AnyConfObj obj' = fid obj == fid obj'

data SpielAddress = SpielAddress
  { sa_confds_fid :: [Fid]
  , sa_confds_ep :: [String]
  , sa_rm_fid :: Fid
  , sa_rm_ep :: String
  , sa_quorum :: Int -- ^ number of the confd required for quorum.
  } deriving (Eq, Show, Generic, Typeable)

instance Binary SpielAddress
instance Hashable SpielAddress

data SyncToConfd =
      SyncToConfdServersInRG Bool
      -- | Used by halonctl
    | SyncDumpToBS ProcessId
  deriving (Eq, Show, Generic, Typeable)

instance Hashable SyncToConfd

storageIndex ''SyncToConfd "6990a155-7db8-48a9-91e8-d49b75d16b25"
deriveSafeCopy 0 'base ''SyncToConfd

newtype SyncDumpToBSReply = SyncDumpToBSReply (Either String BS.ByteString)
  deriving (Eq, Show, Binary, Generic, Hashable, Typeable)

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
instance ToJSON At

storageIndex ''At "faa2ba1b-b989-468b-98f2-d38859a6b566"
deriveSafeCopy 0 'base ''At

-- | Relationship between parent and child entities in confd
--   Directed from parent to child (e.g. profile IsParentOf filesystem)
data IsParentOf = IsParentOf
  deriving (Eq, Show, Generic, Typeable)

instance Hashable IsParentOf
instance ToJSON IsParentOf

storageIndex ''IsParentOf "5e8df2ad-26c9-4614-8f66-4c9a31f044eb"
deriveSafeCopy 0 'base ''IsParentOf

-- | Relationship between virtual and real entities in confd.
--   Directed from real to virtual (e.g. rack IsRealOf rackv)
data IsRealOf = IsRealOf
  deriving (Eq, Show, Generic, Typeable)

instance Hashable IsRealOf
instance ToJSON IsRealOf

storageIndex ''IsRealOf "5be580c1-5dfa-4e01-ae27-ccf6739746c9"
deriveSafeCopy 0 'base ''IsRealOf

-- | Relationship between conceptual and hardware entities in confd
--   Directed from sdev to disk (e.g. sdev IsOnHardware disk)
--   Directed from node to controller (e.g. node IsOnHardware controller)
data IsOnHardware = IsOnHardware
  deriving (Eq, Show, Generic, Typeable)

instance Hashable IsOnHardware
instance ToJSON IsOnHardware

storageIndex ''IsOnHardware "82dcc778-1702-4061-8b4b-c660896c9193"
deriveSafeCopy 0 'base ''IsOnHardware

newtype Root = Root Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj Root where
   fidType _ = fromIntegral . ord $ 't'
   fid (Root f) = f

storageIndex ''Root "c5bc3158-9ff7-4fae-93c8-ed9f8d623991"
deriveSafeCopy 0 'base ''Root

newtype Profile = Profile Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, FromJSON, ToJSON)

instance ConfObj Profile where
  fidType _ = fromIntegral . ord $ 'p'
  fid (Profile f) = f

storageIndex ''Profile "5c1bed0a-414a-4567-ba32-4263ab4b52b7"
deriveSafeCopy 0 'base ''Profile

-- XXX-MULTIPOOLS: Change to root
data Filesystem = Filesystem
  { f_fid :: Fid
  , f_mdpool_fid :: Fid -- ^ Fid of filesystem metadata pool
  , f_imeta_fid :: Fid -- ^ Fid of the imeta pver
  } deriving (Eq, Show, Ord, Generic, Typeable)

instance Hashable Filesystem
instance ToJSON Filesystem
instance FromJSON Filesystem

-- XXX-MULTIPOOLS: Change to root
instance ConfObj Filesystem where
  fidType _ = fromIntegral . ord $ 'f'
  fid = f_fid

storageIndex ''Filesystem "5c783c2a-f112-4364-b6b9-4e8f54387d11"
deriveSafeCopy 0 'base ''Filesystem

-- | Marker to indicate the DIX subsystem has been initialised.
data DIXInitialised = DIXInitialised
  deriving (Eq, Show, Generic, Typeable)

instance Hashable DIXInitialised
instance ToJSON DIXInitialised
instance FromJSON DIXInitialised

storageIndex ''DIXInitialised "e36d8c47-62d8-466c-88d7-bd1255776be0"
deriveSafeCopy 0 'base ''DIXInitialised

newtype Node = Node Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, Ord, FromJSON, ToJSON)

instance ConfObj Node where
  fidType _ = fromIntegral . ord $ 'n'
  fid (Node f) = f

storageIndex ''Node "ad7ccb0d-546a-41d0-a332-6a4f3d842a15"
deriveSafeCopy 0 'base ''Node

-- | Node state. This is a generalization of what might be reported to Mero.
data NodeState
  = NSUnknown             -- ^ Node state is not known.
  | NSOffline             -- ^ Node is stopped, gracefully.
  | NSFailedUnrecoverable -- ^ Node is failed
  | NSFailed              -- ^ Node is failed, possibly can be recovered.
  | NSOnline              -- ^ Node is online.
  deriving (Eq, Ord, Read, Show, Generic, Typeable)

instance Hashable NodeState
instance ToJSON NodeState
instance FromJSON NodeState

storageIndex ''NodeState "20e7c791-34ab-48b0-87d5-0ad9a7931f3a"
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
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj Rack where
  fidType _ = fromIntegral . ord $ 'a'
  fid (Rack f) = f

storageIndex ''Rack "967502a2-03df-4750-a4de-b1d9c1be20fa"
deriveSafeCopy 0 'base ''Rack

newtype Pool = Pool Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, Ord, FromJSON, ToJSON)

instance ConfObj Pool where
  fidType _ = fromIntegral . ord $ 'o'
  fid (Pool f) = f

storageIndex ''Pool "9e348e20-a996-47d2-b5d6-5ba04b952d35"
deriveSafeCopy 0 'base ''Pool

data Process = Process
  { r_fid :: !Fid
  , r_mem_as :: !Word64
  , r_mem_rss :: !Word64
  , r_mem_stack :: !Word64
  , r_mem_memlock :: !Word64
  , r_cores :: !Bitmap
  , r_endpoint :: !Endpoint
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable Process
instance ToJSON Process
instance FromJSON Process

instance ConfObj Process where
  fidType _ = fromIntegral . ord $ 'r'
  fid = r_fid

instance Ord Process where
  compare = comparing r_fid

storageIndex ''Process "7d76bc51-c2ee-4cbf-bbfc-19276403e500"
deriveSafeCopy 0 'base ''Process

data Service_v0 = Service_v0
  { s_fid_v0 :: Fid
  , s_type_v0 :: ServiceType -- ^ e.g. ioservice, haservice
  , s_endpoints_v0 :: [String]
  , s_params_v0 :: ServiceParams
  } deriving (Eq, Show, Generic, Typeable)

data Service = Service
  { s_fid :: Fid
  , s_type :: ServiceType -- ^ e.g. ioservice, haservice
  , s_endpoints :: [Endpoint]
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable Service
instance ToJSON Service
instance FromJSON Service

instance ConfObj Service where
  fidType _ = fromIntegral . ord $ 's'
  fid = s_fid

instance Migrate Service where
  type MigrateFrom Service = Service_v0
  migrate v0 = Service (s_fid_v0 v0) (s_type_v0 v0)
                       (rights $ readEndpoint . T.pack <$> s_endpoints_v0 v0)

instance Ord Service where
  compare = comparing s_fid

storageIndex ''Service "2f7bd43d-767a-4c6d-9586-ef369528f2e2"
deriveSafeCopy 0 'base ''Service_v0
deriveSafeCopy 1 'extension ''Service

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
  deriving (Eq, Ord, Read, Show, Generic, Typeable)

instance Hashable ServiceState
instance ToJSON ServiceState
instance FromJSON ServiceState

storageIndex ''ServiceState "59f1f98a-bcf8-4707-8652-3ab10ed78ecb"
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

data SDev = SDev
  { d_fid :: Fid
  , d_idx :: Word32 -- ^ Index of device in pool
  , d_size :: Word64 -- ^ Size in mb
  , d_bsize :: Word32 -- ^ Block size in mb
  , d_path :: String -- ^ Path to logical device
  } deriving (Eq, Ord, Show, Generic, Typeable)

instance Hashable SDev
instance ToJSON SDev
instance FromJSON SDev

instance ConfObj SDev where
  fidType _ = fromIntegral . ord $ 'd'
  fid = d_fid

storageIndex ''SDev "3b07bf77-c5f9-4a42-bae9-6c658272b3a1"
deriveSafeCopy 0 'base ''SDev

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
  deriving (Eq, Ord, Read, Show, Generic, Typeable)

instance Hashable SDevState
instance ToJSON SDevState
instance FromJSON SDevState

storageIndex ''SDevState "9b261aec-81d9-42a7-a0f5-0e6463c9789a"
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
--   this will result in @x@ becoming @SDSTransient x@, but with
--   exceptions where the device is failed (including SNS) or already
--   transient.
sdsFailTransient :: SDevState -> SDevState
sdsFailTransient SDSFailed = SDSFailed
sdsFailTransient SDSRepairing = SDSRepairing
sdsFailTransient SDSRepaired = SDSRepaired
sdsFailTransient SDSRebalancing = SDSRebalancing
sdsFailTransient s@(SDSTransient _) = s
sdsFailTransient (SDSInhibited x) = SDSInhibited $ sdsFailTransient x
sdsFailTransient x = SDSTransient x

newtype Enclosure = Enclosure Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj Enclosure where
  fidType _ = fromIntegral . ord $ 'e'
  fid (Enclosure f) = f

storageIndex ''Enclosure "c532aff7-0a81-4949-9f52-3963c7871250"
deriveSafeCopy 0 'base ''Enclosure

-- | A controller represents an entity which allows access to a number of
--   disks. It will typically be hosted on a node.
newtype Controller = Controller Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, FromJSON, ToJSON)

instance ConfObj Controller where
  fidType _ = fromIntegral . ord $ 'c'
  fid (Controller f) = f

storageIndex ''Controller "e0b49549-5ba5-4e2a-9440-81fbfd1b0253"
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
  deriving (Eq, Read, Show, Generic, Typeable)

instance Hashable ControllerState
instance ToJSON ControllerState

storageIndex ''ControllerState "83139b83-4170-47e2-be95-8a726c8159a6"
deriveSafeCopy 0 'base ''ControllerState

newtype Disk = Disk Fid
  deriving (Eq, Ord, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj Disk where
  fidType _ = fromIntegral . ord $ 'k'
  fid (Disk f) = f

storageIndex ''Disk "ab1e2612-33cb-436c-8a37-d6763212db27"
deriveSafeCopy 0 'base ''Disk

-- XXX FIXME: Mixing sum types and record syntax is a terrible thing to do.
data PVerType = PVerActual {
    v_tolerance :: [Word32]
  , v_attrs :: PDClustAttr
} | PVerFormulaic {
    v_id :: Word32
  , v_allowance :: [Word32]
  , v_base  :: Fid
} deriving (Eq, Show, Generic, Typeable)

instance Hashable PVerType
instance ToJSON PVerType

storageIndex ''PVerType "eb620a23-ffd8-4705-871f-c0674ad84cb7"
deriveSafeCopy 0 'base ''PVerType

data PVer = PVer
  { v_fid :: Fid
  , v_type :: PVerType
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable PVer
instance ToJSON PVer

storageIndex ''PVer "055c3f88-4bdd-419a-837b-a029c7f4effd"
deriveSafeCopy 0 'base ''PVer

newtype PVerCounter = PVerCounter Word32
  deriving (Eq, Ord, Show, Generic, Typeable, Hashable, ToJSON)

instance ConfObj PVer where
  fidType _ = fromIntegral . ord $ 'v'
  fid = v_fid

storageIndex ''PVerCounter "e6cce9f1-9bad-4de4-9b0c-b88cadf91200"
deriveSafeCopy 0 'base ''PVerCounter

newtype RackV = RackV Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj RackV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (RackV f) = f

storageIndex ''RackV "23dd6e71-7a5b-48e1-9d1e-9aa2ef6a6994"
deriveSafeCopy 0 'base ''RackV

newtype EnclosureV = EnclosureV Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj EnclosureV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (EnclosureV f) = f

storageIndex ''EnclosureV "f63ac45b-7a36-483c-84c8-739f028b04ed"
deriveSafeCopy 0 'base ''EnclosureV

newtype ControllerV = ControllerV Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj ControllerV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (ControllerV f) = f

storageIndex ''ControllerV "d3ab3c01-198d-4612-9281-ddf8ce217910"
deriveSafeCopy 0 'base ''ControllerV

newtype DiskV = DiskV Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj DiskV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (DiskV f) = f

storageIndex ''DiskV "31526120-34c9-47c8-b63e-8668ee6add27"
deriveSafeCopy 0 'base ''DiskV

-- | Wrapper for 'C.TimeSpec' providing 'Binary' and 'Hashable'
-- instances.
--
-- Normally you should use 'mkTimeSpec' to create these.
--
-- TODO: Move this somewhere else
newtype TimeSpec = TimeSpec { _unTimeSpec :: C.TimeSpec }
  deriving (Eq, Num, Ord, Read, Show, Generic, Typeable)

storageIndex ''TimeSpec "fb1d3f0b-5761-41a3-b14a-ca5f458180b6"
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

instance Hashable PoolRepairType
instance ToJSON PoolRepairType
instance FromJSON PoolRepairType

storageIndex ''PoolRepairType "e26504dd-3dfd-4989-872f-180097e755d0"
deriveSafeCopy 0 'base ''PoolRepairType

-- | Information attached to 'PoolRepairStatus'.
data PoolRepairInformation_v0 = PoolRepairInformation_v0
  { priOnlineNotifications_v0 :: Int
  -- ^ Number of online notifications received from IOS.
  , priTimeOfFirstCompletion_v0 :: TimeSpec
  -- ^ Time of completion of the operation by the first IOS.
  , priTimeLastHourlyRan_v0 :: TimeSpec
  -- ^ Time at which the last hourly query has been ran.
  , priStateUpdates_v0      :: [(SDev, Int)]
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable PoolRepairInformation_v0
instance ToJSON PoolRepairInformation_v0
instance FromJSON PoolRepairInformation_v0

deriveSafeCopy 0 'base ''PoolRepairInformation_v0

data PoolRepairInformation = PoolRepairInformation
  { priTimeOfSnsStart :: !TimeSpec
  , priTimeLastHourlyRan :: !TimeSpec
  , priStateUpdates :: ![(SDev, Int)]
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable PoolRepairInformation
instance ToJSON PoolRepairInformation
instance FromJSON PoolRepairInformation

storageIndex ''PoolRepairInformation "2ef9e93c-5351-45e9-8a7d-82caa99bc4e6"
deriveSafeCopy 1 'extension ''PoolRepairInformation

instance Migrate PoolRepairInformation where
  type MigrateFrom PoolRepairInformation = PoolRepairInformation_v0
  migrate pri_v0 = PoolRepairInformation
    { priTimeOfSnsStart = priTimeOfFirstCompletion_v0 pri_v0
    , priTimeLastHourlyRan = priTimeLastHourlyRan_v0 pri_v0
    , priStateUpdates = priStateUpdates_v0 pri_v0
    }

-- | Status of SNS pool repair/rebalance.
data PoolRepairStatus = PoolRepairStatus
  { prsType :: !PoolRepairType
  -- ^ Repair/rebalance?
  , prsRepairUUID :: UUID
  -- ^ UUID used to distinguish SNS operations from different runs on
  -- the same pool.
  , prsPri :: !(Maybe PoolRepairInformation)
  -- ^ Information about the actual SNS operation.
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable PoolRepairStatus
instance ToJSON PoolRepairStatus
instance FromJSON PoolRepairStatus

storageIndex ''PoolRepairStatus "a238bffa-4a36-457d-95e8-2947ed8f45e5"
deriveSafeCopy 0 'base ''PoolRepairStatus

-- | Vector of failed devices. We keep the order of failures because
-- mero should always send information about that to mero in the same
-- order.
newtype DiskFailureVector = DiskFailureVector [Disk]
  deriving (Eq, Ord, Show, Generic, Typeable, Hashable, ToJSON)

storageIndex ''DiskFailureVector "00b766c3-3740-4c9c-afb4-e485fa52b433"
deriveSafeCopy 0 'base ''DiskFailureVector

-- | @lnet@ address associated with a host.
newtype LNid = LNid Lnet.LNid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

storageIndex ''LNid "c46ca6b1-e84a-4981-8aa9-ed2223c91bff"
deriveSafeCopy 0 'base ''LNid

-- | Hardware information about a host.
data HostHardwareInfo = HostHardwareInfo
  { hhMemorySize  :: !Word64
  -- ^ Memory size in MiB
  , hhCpuCount    :: !Int
  -- ^ Number of CPUs
  , hhLNidAddress :: !Lnet.LNid
  -- ^ @lnet@ address
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable HostHardwareInfo
instance ToJSON HostHardwareInfo

storageIndex ''HostHardwareInfo "7b81d801-ff8f-4364-b635-6648fc8614b2"
deriveSafeCopy 0 'base ''HostHardwareInfo

-- | Alias for process ID. In glibc @pid_t = int@.
newtype PID = PID Int
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

storageIndex ''PID "a28fae4e-054b-4442-b81b-9dea98312d3a"
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
  deriving (Eq, Ord, Read, Show, Generic, Typeable)

instance Hashable ProcessState
instance ToJSON ProcessState
instance FromJSON ProcessState

storageIndex ''ProcessState "8bdf4695-22d6-4f21-88a9-27445ad29252"
deriveSafeCopy 0 'base ''ProcessState

-- | Pretty printer for 'ProcessState'.
prettyProcessState :: ProcessState -> String
prettyProcessState PSUnknown = "N/A"
prettyProcessState PSOffline = "offline"
prettyProcessState PSStarting = "starting"
prettyProcessState PSOnline   = "online"
prettyProcessState PSQuiescing   = "quiescing"
prettyProcessState PSStopping = "stopping"
prettyProcessState (PSFailed reason) = "failed (" ++ reason ++ ")"
prettyProcessState (PSInhibited st) = "inhibited (" ++ prettyProcessState st ++ ")"

-- | Pretty-printing preparation for 'ProcessState'.
displayProcessState :: ProcessState -> (String, Maybe String)
displayProcessState s@PSFailed{} = ("failed", Just $ prettyProcessState s)
displayProcessState s@PSInhibited{} = ("inhibited", Just $ prettyProcessState s)
displayProcessState s = (prettyProcessState s, Nothing)

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
newtype BootLevel = BootLevel { unBootLevel :: Int }
  deriving (Eq, Ord, Show, Generic, Hashable, Typeable, FromJSON, ToJSON)

storageIndex ''BootLevel "1d4cb2fc-6dbf-4dd9-ae3e-e48bb7accce7"
deriveSafeCopy 0 'base ''BootLevel

data ProcessLabel_0 =
    PLM0t1fs_0
  | PLBootLevel_0 BootLevel -- ^ Process boot level. Currently 0 = confd, 1 = other0
  | PLNoBoot_0  -- ^ Tag processes which should not boot.
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ProcessLabel_0

deriveSafeCopy 0 'base ''ProcessLabel_0

-- | Label to attach to a Mero process providing extra context about how
--   it should run.
data ProcessLabel =
    PLM0t1fs -- ^ Process lives as part of m0t1fs in kernel space
  | PLClovis String Bool -- ^ Process lives as part of a Clovis client, with
                         --   given name. If the second parameter is set to
                         --   'True', then the process is indendently controlled
                         --   and should not be started/stopped by Halon.
  | PLM0d BootLevel -- ^ Process runs in m0d at the given boot level.
                    --   Currently 0 = confd, 1 = other0
  | PLHalon  -- ^ Process lives inside Halon program space.
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ProcessLabel
instance ToJSON ProcessLabel

storageIndex ''ProcessLabel "4aa03302-90c7-4a6f-85d5-5b8a716b60e3"
deriveSafeCopy 1 'extension ''ProcessLabel

instance Migrate ProcessLabel where
  type MigrateFrom ProcessLabel = ProcessLabel_0
  migrate PLM0t1fs_0 = PLM0t1fs
  migrate (PLBootLevel_0 x) = PLM0d x
  migrate PLNoBoot_0 = PLHalon

-- | Process environment. Values stored here will be added to the environment
--   file for the process.
data ProcessEnv =
    ProcessEnvValue String String
  | ProcessEnvInRange String Int
  deriving (Eq, Ord, Show, Generic, Typeable)

instance Hashable ProcessEnv
instance ToJSON ProcessEnv

storageIndex ''ProcessEnv "9a713802-a47b-4abb-97f6-2cbc35c95431"
deriveSafeCopy 0 'base ''ProcessEnv

-- | Cluster disposition.
--   This represents the desired state for the cluster, which is used to
--   decide upon the correct behaviour to take in reaction to events.
data Disposition =
    ONLINE -- ^ Cluster should be online
  | OFFLINE -- ^ Cluster should be offline (e.g. for maintenance)
  deriving (Eq, Show, Generic, Typeable)

instance Hashable Disposition
instance ToJSON Disposition
instance FromJSON Disposition

storageIndex ''Disposition "c84234bf-5d6a-4918-a3fd-82f16b012cb7"
deriveSafeCopy 0 'base ''Disposition

-- | Marker to tag the cluster run level
data RunLevel = RunLevel
  deriving (Eq, Show, Generic, Typeable)

instance Hashable RunLevel
instance ToJSON RunLevel

storageIndex ''RunLevel "534ecce0-42bf-4618-ae24-dbb235ce5dec"
deriveSafeCopy 0 'base ''RunLevel

-- | Marker to tag the cluster stop level
data StopLevel = StopLevel
  deriving (Eq, Show, Generic, Typeable)

instance Hashable StopLevel
instance ToJSON StopLevel

storageIndex ''StopLevel "65ff0e97-9a9f-47f8-8d80-b5ddce912985"
deriveSafeCopy 0 'base ''StopLevel

-- | Cluster state.
--   We do not store this cluster state in the graph, but it's a useful
--   aggregation for sending to clients.
data MeroClusterState = MeroClusterState
  { _mcs_disposition :: Disposition
  , _mcs_runlevel :: BootLevel
  , _mcs_stoplevel :: BootLevel
  } deriving (Eq, Show, Generic, Typeable)

instance Binary MeroClusterState
instance FromJSON MeroClusterState
instance ToJSON MeroClusterState

-- | Pretty-printer for 'MeroClusterState'.
prettyStatus :: MeroClusterState -> String
prettyStatus MeroClusterState{..} = unlines
  [ "Disposition: " ++ show _mcs_disposition
  , "Current run level: " ++ show (unBootLevel _mcs_runlevel)
  , "Current stop level: " ++ show (unBootLevel _mcs_stoplevel)
  ]

-- | Information about the update state of the conf database. Holds
-- version number of the current data and its hash. When we want to
-- potentially update the database, we don't want to recommit and
-- increase the version number when no actual changes have happened:
-- we can just check against the hash if we actually have some changes
-- to commit.
data ConfUpdateVersion = ConfUpdateVersion Word64 (Maybe Int)
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ConfUpdateVersion
instance ToJSON ConfUpdateVersion

storageIndex ''ConfUpdateVersion "0792089d-38c7-4993-8e7b-fcc30dd2ca33"
deriveSafeCopy 0 'base ''ConfUpdateVersion

-- | Process property, that shows that process was already bootstrapped,
-- and no mkfs is needed.
data ProcessBootstrapped = ProcessBootstrapped
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ProcessBootstrapped
instance ToJSON ProcessBootstrapped

storageIndex ''ProcessBootstrapped "2f8e34ff-5c7f-4d85-99cf-8a6c0a4f09cc"
deriveSafeCopy 0 'base ''ProcessBootstrapped

-- | Filesystem statistics.
data FilesystemStats = FilesystemStats -- XXX-MULTIPOOLS: s/Filesystem//
  { _fs_fetched_on :: TimeSpec
  , _fs_stats :: FSStats
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable FilesystemStats
instance ToJSON FilesystemStats
instance FromJSON FilesystemStats

storageIndex ''FSStats "914ee8ee-e8fb-453c-893c-5e386cdb28e3"
deriveSafeCopy 0 'base ''FSStats
storageIndex ''FilesystemStats "cc95cff6-abb5-474a-aad9-44acdf1d5e4a"
deriveSafeCopy 0 'base ''FilesystemStats

-- | A disk marker for replaced disks.
data Replaced = Replaced
  deriving (Eq, Show, Generic, Typeable)

instance Hashable Replaced
instance ToJSON Replaced
instance FromJSON Replaced

storageIndex ''Replaced "c2bd97c3-c84f-42a2-b14c-0e0240a61b7e"
deriveSafeCopy 0 'base ''Replaced

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(mkDicts
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus, ''LNid
  , ''HostHardwareInfo, ''ProcessLabel, ''ConfUpdateVersion
  , ''Disposition, ''ProcessBootstrapped, ''ProcessEnv
  , ''ProcessState, ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter, ''NodeState, ''ControllerState
  , ''BootLevel, ''RunLevel, ''StopLevel, ''FilesystemStats
  , ''Replaced, ''At, ''IsParentOf, ''IsRealOf, ''IsOnHardware
  , ''DIXInitialised
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
    -- XXX-MULTIPOOLS: retire filesystem, update relations
  , (''Filesystem, ''IsParentOf, ''Node)
  , (''Filesystem, ''IsParentOf, ''Rack)
  , (''Filesystem, ''IsParentOf, ''Pool)
  , (''Node, ''IsParentOf, ''Process)
  , (''Process, ''IsParentOf, ''Service)
  , (''Service, ''IsParentOf, ''SDev)
  , (''Rack, ''IsParentOf, ''Enclosure)
  , (''Enclosure, ''IsParentOf, ''Controller)
  , (''Controller, ''IsParentOf, ''Disk)
  , (''Pool, ''IsParentOf, ''PVer)
  , (''PVer, ''IsParentOf, ''RackV)
  , (''RackV, ''IsParentOf, ''EnclosureV)
  , (''EnclosureV, ''IsParentOf, ''ControllerV)
  , (''ControllerV, ''IsParentOf, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Rack, ''IsRealOf, ''RackV)
  , (''Enclosure, ''IsRealOf, ''EnclosureV)
  , (''Controller, ''IsRealOf, ''ControllerV)
  , (''Disk, ''IsRealOf, ''DiskV)
  , (''Disk, ''R.Is, ''Replaced)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, ''IsOnHardware, ''Disk)
  , (''SDev, ''At, ''R.Slot)
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
  , (''Process, ''R.Has, ''ProcessEnv)
  , (''Process, ''R.Has, ''PID)
  , (''Process, ''R.Is, ''ProcessBootstrapped)
  , (''Process, ''R.Is, ''ProcessState)
  , (''Service, ''R.Is, ''ServiceState)
  , (''SDev, ''R.Is, ''SDevState)
  , (''Node,    ''R.Is, ''NodeState)
  , (''Controller,    ''R.Is, ''ControllerState)
    -- XXX-MULTIPOOLS: retire filesystem, update relations
  , (''Filesystem, ''R.Has, ''FilesystemStats)
  , (''Filesystem, ''R.Is, ''DIXInitialised)
  ]
  )

$(mkResRel
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus, ''LNid
  , ''HostHardwareInfo, ''ProcessLabel, ''ConfUpdateVersion
  , ''Disposition, ''ProcessBootstrapped, ''ProcessEnv
  , ''ProcessState, ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter, ''NodeState, ''ControllerState
  , ''BootLevel, ''RunLevel, ''StopLevel, ''FilesystemStats
  , ''Replaced, ''At, ''IsParentOf, ''IsRealOf, ''IsOnHardware
  , ''DIXInitialised
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
  , (''SDev, AtMostOne, ''At, AtMostOne, ''R.Slot)
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
  , (''Pool, AtMostOne, ''IsParentOf, Unbounded, ''PVer)
  , (''PVer, AtMostOne, ''IsParentOf, Unbounded, ''RackV)
  , (''RackV, AtMostOne, ''IsParentOf, Unbounded, ''EnclosureV)
  , (''EnclosureV, AtMostOne, ''IsParentOf, Unbounded, ''ControllerV)
  , (''ControllerV, AtMostOne, ''IsParentOf, Unbounded, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Rack, AtMostOne, ''IsRealOf, Unbounded, ''RackV)
  , (''Enclosure, AtMostOne, ''IsRealOf, Unbounded, ''EnclosureV)
  , (''Controller, AtMostOne, ''IsRealOf, Unbounded, ''ControllerV)
  , (''Disk, AtMostOne, ''IsRealOf, Unbounded, ''DiskV)
  , (''Disk, Unbounded, ''R.Is, Unbounded, ''Replaced)
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
  , (''Process, Unbounded, ''R.Has, AtMostOne, ''ProcessLabel)
  , (''Process, Unbounded, ''R.Has, Unbounded, ''ProcessEnv)
  , (''Process, Unbounded, ''R.Has, AtMostOne, ''PID)
  , (''Process, Unbounded, ''R.Is, AtMostOne, ''ProcessBootstrapped)
  , (''Process, Unbounded, ''R.Is, AtMostOne, ''ProcessState)
  , (''Service, Unbounded, ''R.Is, AtMostOne, ''ServiceState)
  , (''SDev, Unbounded, ''R.Is, AtMostOne, ''SDevState)
  , (''Node, Unbounded,    ''R.Is, AtMostOne, ''NodeState)
  , (''Controller, Unbounded,    ''R.Is, AtMostOne, ''ControllerState)
  , (''Filesystem, Unbounded, ''R.Has, AtMostOne, ''FilesystemStats)
  , (''Filesystem, Unbounded, ''R.Is, AtMostOne, ''DIXInitialised)
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

-- | Lookup 'Node' associated with the given 'R.Node'. See
-- 'nodeToM0Node' for inverse.
m0nodeToNode :: Node -> G.Graph -> Maybe R.Node
m0nodeToNode m0node rg = listToMaybe
  [ node | Just (h :: R.Host) <- [G.connectedFrom R.Runs m0node rg]
         , node <- G.connectedTo h R.Runs rg ]

-- | Lookup 'R.Node' associated with the given 'Node'. See
-- 'm0nodeToNode' for inverse.
nodeToM0Node :: R.Node -> G.Graph -> Maybe Node
nodeToM0Node node rg = listToMaybe
  [ m0n | Just (h :: R.Host) <- [G.connectedFrom R.Runs node rg]
        , m0n <- G.connectedTo h R.Runs rg ]
