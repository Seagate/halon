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
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
import           Data.Maybe (fromMaybe, listToMaybe)
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
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.TH
import           HA.SafeCopy hiding (Profile)
import           Mero.ConfC (Bitmap, Fid(..), PDClustAttr, ServiceType)
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
--   Directed from parent to child (e.g. pool IsParentOf pver)
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

data Root = Root
  { rt_fid :: Fid
  , rt_mdpool :: Fid -- ^ Meta-data pool.  XXX-MULTIPOOLS: DELETEME
  , rt_imeta_pver :: Fid -- ^ Distributed index meta-data pool version.
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable Root
instance ToJSON Root
instance FromJSON Root

instance ConfObj Root where
  fidType _ = fromIntegral . ord $ 't'
  fid = rt_fid

storageIndex ''Root "553c273e-4ae8-4a0d-8152-1b3d634373e5"
deriveSafeCopy 0 'base ''Root

newtype Profile = Profile Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, FromJSON, ToJSON)

instance ConfObj Profile where
  fidType _ = fromIntegral . ord $ 'p'
  fid (Profile f) = f

storageIndex ''Profile "5c1bed0a-414a-4567-ba32-4263ab4b52b7"
deriveSafeCopy 0 'base ''Profile

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
  | NSRebalance           -- ^ Node is replaced, rebalance it.
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
prettyNodeState NSRebalance = "rebalancing"

displayNodeState :: NodeState -> (String, Maybe String)
displayNodeState xs@NSFailed = ("failed", Just $ prettyNodeState xs)
displayNodeState xs@NSFailedUnrecoverable = ("failed", Just $ prettyNodeState xs)
displayNodeState xs = (prettyNodeState xs, Nothing)

newtype Site = Site Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj Site where
  fidType _ = fromIntegral . ord $ 'S'
  fid (Site f) = f

storageIndex ''Site "7d026dd3-ee2d-42d2-85f8-e4c15738cf79"
deriveSafeCopy 0 'base ''Site

newtype Rack = Rack Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj Rack where
  fidType _ = fromIntegral . ord $ 'a'
  fid (Rack f) = f

storageIndex ''Rack "967502a2-03df-4750-a4de-b1d9c1be20fa"
deriveSafeCopy 0 'base ''Rack

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

newtype Disk = Disk Fid -- XXX-MULTIPOOLS: s/Disk/Drive/
  deriving (Eq, Ord, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj Disk where
  fidType _ = fromIntegral . ord $ 'k'
  fid (Disk f) = f

storageIndex ''Disk "ab1e2612-33cb-436c-8a37-d6763212db27"
deriveSafeCopy 0 'base ''Disk

newtype Pool = Pool Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, Ord, FromJSON, ToJSON)

instance ConfObj Pool where
  fidType _ = fromIntegral . ord $ 'o'
  fid (Pool f) = f

storageIndex ''Pool "9e348e20-a996-47d2-b5d6-5ba04b952d35"
deriveSafeCopy 0 'base ''Pool

-- | 'pool_id' from the facts.yaml file.
-- Only SNS pools have this attribute.
newtype PoolId = PoolId T.Text
  deriving (Eq, Show, Hashable, FromJSON, ToJSON)

storageIndex ''PoolId "c320a02f-0068-4b46-ba70-aad26b048f43"
deriveSafeCopy 0 'base ''PoolId

data PVerActual = PVerActual
  { va_attrs :: PDClustAttr
  , va_tolerance :: [Word32]
    -- ^ XXX A list type is not rigid enough.  Consider making it
    -- a vector of exactly M0_CONF_PVER_HEIGHT elements.
    -- See `fixed-length` package.
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable PVerActual
instance ToJSON PVerActual

storageIndex ''PVerActual "b8c311f6-bf87-4ff3-8b46-485cd463dda1"
deriveSafeCopy 0 'base ''PVerActual

data PVerFormulaic = PVerFormulaic
  { vf_id :: Word32
  , vf_base :: Fid
  , vf_allowance :: [Word32]
    -- ^ XXX Make it a vector of exactly M0_CONF_PVER_HEIGHT elements.
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable PVerFormulaic
instance ToJSON PVerFormulaic

storageIndex ''PVerFormulaic "278a3e83-f9c3-4800-9944-a7583012e8ab"
deriveSafeCopy 0 'base ''PVerFormulaic

data PVer = PVer
  { v_fid :: Fid
  , v_data :: Either PVerFormulaic PVerActual
  } deriving (Eq, Show, Generic, Typeable)

instance Hashable PVer
instance ToJSON PVer

storageIndex ''PVer "055c3f88-4bdd-419a-837b-a029c7f4effd"
deriveSafeCopy 0 'base ''PVer

instance ConfObj PVer where
  fidType _ = fromIntegral . ord $ 'v'
  fid = v_fid

newtype PVerCounter = PVerCounter Word32
  deriving (Eq, Ord, Show, Generic, Typeable, Hashable, ToJSON)

storageIndex ''PVerCounter "e6cce9f1-9bad-4de4-9b0c-b88cadf91200"
deriveSafeCopy 0 'base ''PVerCounter

-- | Marker for a meta-data pool version.
data MetadataPVer = MetadataPVer
  deriving (Eq, Show, Generic, Typeable)

instance Hashable MetadataPVer
instance ToJSON MetadataPVer

storageIndex ''MetadataPVer "e38673d3-9c38-44d6-b1f2-1e52aee84a6f"
deriveSafeCopy 0 'base ''MetadataPVer

newtype SiteV = SiteV Fid
  deriving (Eq, Show, Generic, Hashable, Typeable, ToJSON)

instance ConfObj SiteV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (SiteV f) = f

storageIndex ''SiteV "18e22f85-0e2c-4e43-9bce-5c87047e0ff7"
deriveSafeCopy 0 'base ''SiteV

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

newtype DiskV = DiskV Fid -- XXX-MULTIPOOLS: s/DiskV/DriveV/
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

instance Hashable TimeSpec where
  hashWithSalt s (TimeSpec (C.TimeSpec sec nsec)) = hashWithSalt s (sec, nsec)

-- | Extract the seconds value from a 'TimeSpec'.
--
-- Warning: casts from 'Int64' to 'Int'.
timeSpecToSeconds :: TimeSpec -> Int
timeSpecToSeconds = fromIntegral . C.sec . _unTimeSpec

-- | Convert 'TimeSpec' to nanoseconds.
timeSpecToNanoSecs :: TimeSpec -> Integer
timeSpecToNanoSecs = C.toNanoSecs . _unTimeSpec

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
data PoolRepairType = Repair | Rebalance
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
  , priStateUpdates :: ![(SDev, Int)]  -- XXX TODO: Replace Int with a meaningful type.
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

data NodeDiRebInformation = NodeDiRebInformation
  { nriTimeOfSnsStart :: !TimeSpec
  , nriTimeLastHourlyRan :: !TimeSpec
  , nriStateUpdates :: ![(SDev, Int)]
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable NodeDiRebInformation
instance ToJSON NodeDiRebInformation
instance FromJSON NodeDiRebInformation

storageIndex ''NodeDiRebInformation "633abe43-8be5-4b8d-9ab8-e84482c91a56"
deriveSafeCopy 0 'base ''NodeDiRebInformation

-- | Status of SNS node direct rebalance.
data NodeDiRebStatus = NodeDiRebStatus
  { nrsRebalanceUUID :: UUID
  -- ^ UUID used to distinguish SNS operations from different runs on
  -- the same pool.
  , nrsNri :: !(Maybe NodeDiRebInformation)
  -- ^ Information about the actual node rebalance operation.
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable NodeDiRebStatus
instance ToJSON NodeDiRebStatus
instance FromJSON NodeDiRebStatus

storageIndex ''NodeDiRebStatus "11b9a921-4cd9-438e-b069-71da1d4ef6fa"
deriveSafeCopy 0 'base ''NodeDiRebStatus

-- | Vector of failed devices. We keep the order of failures because
-- halon should always send information about that to mero in the same
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
data FilesystemStats = FilesystemStats
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
  [ ''FidSeq, ''Profile, ''Node, ''Site, ''Rack, ''Pool, ''PoolId
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''SiteV, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus
  , ''NodeDiRebStatus, ''MetadataPVer, ''LNid, ''HostHardwareInfo
  , ''CI.ProcessType, ''ConfUpdateVersion, ''Disposition
  , ''ProcessBootstrapped, ''ProcessEnv, ''ProcessState
  , ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter, ''NodeState, ''ControllerState
  , ''BootLevel, ''RunLevel, ''StopLevel, ''FilesystemStats
  , ''Replaced, ''At, ''IsParentOf, ''IsRealOf, ''IsOnHardware
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Root)
  , (''R.Cluster, ''R.Has, ''Disposition)
  , (''R.Cluster, ''R.Has, ''PVerCounter)
  , (''R.Cluster, ''R.Has, ''ConfUpdateVersion)
  , (''Controller, ''At, ''Cas.Host)
  , (''Site, ''At, ''Cas.Site)
  , (''Rack, ''At, ''Cas.Rack)
  , (''Enclosure, ''At, ''Cas.Enclosure)
  , (''Disk, ''At, ''Cas.StorageDevice)
    -- Parent/child relationships between conf entities
  , (''Root, ''IsParentOf, ''Profile)
  , (''Root, ''IsParentOf, ''Site)
  , (''Root, ''IsParentOf, ''Node)
  , (''Root, ''IsParentOf, ''Pool)
  , (''Node, ''IsParentOf, ''Process)
  , (''Process, ''IsParentOf, ''Service)
  , (''Service, ''IsParentOf, ''SDev)
  , (''Site, ''IsParentOf, ''Rack)
  , (''Rack, ''IsParentOf, ''Enclosure)
  , (''Enclosure, ''IsParentOf, ''Controller)
  , (''Controller, ''IsParentOf, ''Disk)
  , (''Pool, ''IsParentOf, ''PVer)
  , (''PVer, ''IsParentOf, ''SiteV)
  , (''SiteV, ''IsParentOf, ''RackV)
  , (''RackV, ''IsParentOf, ''EnclosureV)
  , (''EnclosureV, ''IsParentOf, ''ControllerV)
  , (''ControllerV, ''IsParentOf, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Site, ''IsRealOf, ''SiteV)
  , (''Rack, ''IsRealOf, ''RackV)
  , (''Enclosure, ''IsRealOf, ''EnclosureV)
  , (''Controller, ''IsRealOf, ''ControllerV)
  , (''Disk, ''IsRealOf, ''DiskV)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, ''IsOnHardware, ''Disk)
  , (''SDev, ''At, ''Cas.Slot)
  , (''Node, ''IsOnHardware, ''Controller)
  , (''Profile, ''R.Has, ''Pool)
    -- Other things
  , (''R.Cluster, ''R.Has, ''FidSeq)
  , (''R.Cluster, ''R.Has, ''CI.M0Globals)
  , (''R.Cluster, ''RunLevel, ''BootLevel)
  , (''R.Cluster, ''StopLevel, ''BootLevel)
  , (''Pool, ''R.Has, ''PoolRepairStatus)
  , (''Pool, ''R.Has, ''DiskFailureVector)
  , (''Pool, ''R.Has, ''PoolId)
  , (''PVer, ''Cas.Is, ''MetadataPVer)
  , (''Cas.Host, ''R.Has, ''LNid)
  , (''Cas.Host, ''R.Runs, ''Node)
  , (''Process, ''R.Has, ''CI.ProcessType)
  , (''Process, ''R.Has, ''ProcessEnv)
  , (''Process, ''R.Has, ''PID)
  , (''Process, ''Cas.Is, ''ProcessBootstrapped)
  , (''Process, ''Cas.Is, ''ProcessState)
  , (''Service, ''Cas.Is, ''ServiceState)
  , (''SDev, ''Cas.Is, ''SDevState)
  , (''Node, ''R.Has, ''NodeDiRebStatus)
  , (''Node, ''Cas.Is, ''NodeState)
  , (''Controller, ''Cas.Is, ''ControllerState)
  , (''Disk, ''Cas.Is, ''Replaced)
  , (''Root, ''R.Has, ''FilesystemStats)
  ]
  )

$(mkResRel
  [ ''FidSeq, ''Profile, ''Node, ''Site, ''Rack, ''Pool, ''PoolId
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''SiteV, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals, ''Root, ''PoolRepairStatus
  , ''NodeDiRebStatus, ''MetadataPVer, ''LNid, ''HostHardwareInfo
  , ''CI.ProcessType, ''ConfUpdateVersion, ''Disposition
  , ''ProcessBootstrapped, ''ProcessEnv, ''ProcessState
  , ''DiskFailureVector, ''ServiceState, ''PID
  , ''SDevState, ''PVerCounter, ''NodeState, ''ControllerState
  , ''BootLevel, ''RunLevel, ''StopLevel, ''FilesystemStats
  , ''Replaced, ''At, ''IsParentOf, ''IsRealOf, ''IsOnHardware
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''Root)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''Disposition)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''PVerCounter)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''ConfUpdateVersion)
  , (''Controller, AtMostOne, ''At, AtMostOne, ''Cas.Host)
  , (''Site, AtMostOne, ''At, AtMostOne, ''Cas.Site)
  , (''Rack, AtMostOne, ''At, AtMostOne, ''Cas.Rack)
  , (''Enclosure, AtMostOne, ''At, AtMostOne, ''Cas.Enclosure)
  , (''Disk, AtMostOne, ''At, AtMostOne, ''Cas.StorageDevice)
  , (''SDev, AtMostOne, ''At, AtMostOne, ''Cas.Slot)
    -- Parent/child relationships between conf entities
  , (''Root, AtMostOne, ''IsParentOf, Unbounded, ''Profile)
  , (''Root, AtMostOne, ''IsParentOf, Unbounded, ''Site)
  , (''Root, AtMostOne, ''IsParentOf, Unbounded, ''Node)
  , (''Root, AtMostOne, ''IsParentOf, Unbounded, ''Pool)
  , (''Node, AtMostOne, ''IsParentOf, Unbounded, ''Process)
  , (''Process, AtMostOne, ''IsParentOf, Unbounded, ''Service)
  , (''Service, AtMostOne, ''IsParentOf, Unbounded, ''SDev)
  , (''Site, AtMostOne, ''IsParentOf, Unbounded, ''Rack)
  , (''Rack, AtMostOne, ''IsParentOf, Unbounded, ''Enclosure)
  , (''Enclosure, AtMostOne, ''IsParentOf, Unbounded, ''Controller)
  , (''Controller, AtMostOne, ''IsParentOf, Unbounded, ''Disk)
  , (''Pool, AtMostOne, ''IsParentOf, Unbounded, ''PVer)
  , (''PVer, AtMostOne, ''IsParentOf, Unbounded, ''SiteV)
  , (''SiteV, AtMostOne, ''IsParentOf, Unbounded, ''RackV)
  , (''RackV, AtMostOne, ''IsParentOf, Unbounded, ''EnclosureV)
  , (''EnclosureV, AtMostOne, ''IsParentOf, Unbounded, ''ControllerV)
  , (''ControllerV, AtMostOne, ''IsParentOf, Unbounded, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Site, AtMostOne, ''IsRealOf, Unbounded, ''SiteV)
  , (''Rack, AtMostOne, ''IsRealOf, Unbounded, ''RackV)
  , (''Enclosure, AtMostOne, ''IsRealOf, Unbounded, ''EnclosureV)
  , (''Controller, AtMostOne, ''IsRealOf, Unbounded, ''ControllerV)
  , (''Disk, AtMostOne, ''IsRealOf, Unbounded, ''DiskV)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, AtMostOne, ''IsOnHardware, AtMostOne, ''Disk)
  , (''Node, AtMostOne, ''IsOnHardware, AtMostOne, ''Controller)
  , (''Profile, AtMostOne, ''R.Has, Unbounded, ''Pool)
    -- Other things!
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''FidSeq)
  , (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''CI.M0Globals)
  , (''R.Cluster, AtMostOne, ''RunLevel, AtMostOne, ''BootLevel)
  , (''R.Cluster, AtMostOne, ''StopLevel, AtMostOne, ''BootLevel)
  , (''Pool, AtMostOne, ''R.Has, AtMostOne, ''PoolRepairStatus)
  , (''Pool, Unbounded, ''R.Has, AtMostOne, ''DiskFailureVector)
  , (''Pool, AtMostOne, ''R.Has, AtMostOne, ''PoolId)
  , (''PVer, Unbounded, ''Cas.Is, AtMostOne, ''MetadataPVer)
  , (''Cas.Host, AtMostOne, ''R.Has, Unbounded, ''LNid)
  , (''Cas.Host, AtMostOne, ''R.Runs, Unbounded, ''Node)
  , (''Process, Unbounded, ''R.Has, AtMostOne, ''CI.ProcessType)
  , (''Process, Unbounded, ''R.Has, Unbounded, ''ProcessEnv)
  , (''Process, Unbounded, ''R.Has, AtMostOne, ''PID)
  , (''Process, Unbounded, ''Cas.Is, AtMostOne, ''ProcessBootstrapped)
  , (''Process, Unbounded, ''Cas.Is, AtMostOne, ''ProcessState)
  , (''Service, Unbounded, ''Cas.Is, AtMostOne, ''ServiceState)
  , (''SDev, Unbounded, ''Cas.Is, AtMostOne, ''SDevState)
  , (''Node, Unbounded, ''Cas.Is, AtMostOne, ''NodeState)
  , (''Node, Unbounded, ''R.Has, AtMostOne, ''NodeDiRebStatus)
  , (''Controller, Unbounded, ''Cas.Is, AtMostOne, ''ControllerState)
  , (''Disk, Unbounded, ''Cas.Is, AtMostOne, ''Replaced)
  , (''Root, AtMostOne, ''R.Has, AtMostOne, ''FilesystemStats)
  ]
  []
  )

getM0Root :: G.Graph -> Root -- XXX FIXME: s/Root/Maybe Root/
getM0Root = let err = error "getM0Root: Root is not linked to Cluster"
            in fromMaybe err . G.connectedTo R.Cluster R.Has

-- | Get all 'Node's running on the 'Cluster'.
getM0Nodes :: G.Graph -> [Node]
getM0Nodes rg = G.connectedTo (getM0Root rg) IsParentOf rg

-- | Get all 'Process'es running on the 'Cluster'.
getM0Processes :: G.Graph -> [Process]
getM0Processes rg =
  [ proc | node <- getM0Nodes rg
         , proc <- G.connectedTo node IsParentOf rg
  ]

-- | Get all 'Service's running on the 'Cluster'.
getM0Services :: G.Graph -> [Service]
getM0Services rg =
  [ svc | proc <- getM0Processes rg
        , svc <- G.connectedTo proc IsParentOf rg
  ]

-- | Get all 'Profile's running on the 'Cluster'.
getM0Profiles :: G.Graph -> [Profile]
getM0Profiles rg = G.connectedTo (getM0Root rg) IsParentOf rg

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
  [ node | Just (h :: Cas.Host) <- [G.connectedFrom R.Runs m0node rg]
         , node <- G.connectedTo h R.Runs rg ]

-- | Lookup 'R.Node' associated with the given 'Node'. See
-- 'm0nodeToNode' for inverse.
nodeToM0Node :: R.Node -> G.Graph -> Maybe Node
nodeToM0Node node rg = listToMaybe
  [ m0n | Just (h :: Cas.Host) <- [G.connectedFrom R.Runs node rg]
        , m0n <- G.connectedTo h R.Runs rg ]

-- | Lookup current boot level of the cluster. See 'BootLevel'.
getM0BootLevelValue :: G.Graph -> Maybe Int
getM0BootLevelValue g = unBootLevel <$> G.connectedTo R.Cluster RunLevel g
