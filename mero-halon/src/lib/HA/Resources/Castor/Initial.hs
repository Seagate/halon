{-# LANGUAGE CPP                        #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Initial resource load for Castor cluster.
-- This module should be imported qualified.

module HA.Resources.Castor.Initial where

#ifdef USE_MERO
import Mero.ConfC (ServiceParams, ServiceType)
#endif

import Data.Aeson
import Data.Binary (Binary)
import Data.Data
import Data.Hashable (Hashable)
import Data.Word
  ( Word32
#ifdef USE_MERO
  , Word64
#endif
  )

import GHC.Generics (Generic)

data Network = Data | Management | Local
  deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Network
instance Hashable Network
instance FromJSON Network
instance ToJSON Network

data Interface = Interface {
    if_macAddress :: String
  , if_network :: Network
  , if_ipAddrs :: [String]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Interface
instance Hashable Interface
instance FromJSON Interface
instance ToJSON Interface

data Host = Host {
    h_fqdn :: String
  , h_interfaces :: [Interface]
  , h_memsize :: Word32 -- ^ Memory in MB
  , h_cpucount :: Word32 -- ^ Number of CPUs
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Host
instance Hashable Host
instance FromJSON Host
instance ToJSON Host

data BMC = BMC {
    bmc_addr :: String
  , bmc_user :: String
  , bmc_pass :: String
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary BMC
instance Hashable BMC
instance FromJSON BMC
instance ToJSON BMC

data Enclosure = Enclosure {
    enc_idx :: Int
  , enc_id :: String
  , enc_bmc :: [BMC]
  , enc_hosts :: [Host]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Enclosure
instance Hashable Enclosure
instance FromJSON Enclosure
instance ToJSON Enclosure

data Rack = Rack {
    rack_idx :: Int
  , rack_enclosures :: [Enclosure]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Rack
instance Hashable Rack
instance FromJSON Rack
instance ToJSON Rack

#ifdef USE_MERO

data FailureSetScheme =
    Preloaded Word32 Word32 Word32
  | Dynamic
  deriving (Eq, Data, Generic, Show, Typeable)

instance Binary FailureSetScheme
instance Hashable FailureSetScheme
instance FromJSON FailureSetScheme
instance ToJSON FailureSetScheme

data M0Globals = M0Globals {
    m0_data_units :: Word32 -- ^ As in genders
  , m0_parity_units :: Word32  -- ^ As in genders
  , m0_md_redundancy :: Word32 -- ^ Metadata redundancy count
  , m0_failure_set_gen :: FailureSetScheme
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Globals
instance Hashable M0Globals
instance FromJSON M0Globals
instance ToJSON M0Globals

data M0Device = M0Device {
    m0d_wwn :: String
  , m0d_serial :: String
  , m0d_bsize :: Word32 -- ^ Block size
  , m0d_size :: Word64 -- ^ Size of disk (in MB)
  , m0d_path :: String -- ^ Path to the device (e.g. /dev/disk...)
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Device
instance Hashable M0Device
instance FromJSON M0Device
instance ToJSON M0Device

-- | Represents an aggregation of three Mero concepts, which we don't
--   necessarily need for the castor implementation - nodes, controllers, and
--   processes.
data M0Host = M0Host {
    m0h_fqdn :: String -- ^ FQDN of host this server is running on
  , m0h_processes :: [M0Process]
  , m0h_devices :: [M0Device]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Host
instance Hashable M0Host
instance FromJSON M0Host
instance ToJSON M0Host

data M0Process = M0Process {
    m0p_endpoint :: String
  , m0p_mem_as :: Word64
  , m0p_mem_rss :: Word64
  , m0p_mem_stack :: Word64
  , m0p_mem_memlock :: Word64
  , m0p_cores :: [Word64]
    -- ^ Treated as a bitmap of length (no_cpu) indicating which CPUs to use
  , m0p_services :: [M0Service]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Process
instance Hashable M0Process
instance FromJSON M0Process
instance ToJSON M0Process

data M0Service = M0Service {
    m0s_type :: ServiceType -- ^ e.g. ioservice, haservice
  , m0s_endpoints :: [String]
  , m0s_params :: ServiceParams
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Service
instance Hashable M0Service
instance FromJSON M0Service
instance ToJSON M0Service

#endif

data InitialData = InitialData {
    id_racks :: [Rack]
#ifdef USE_MERO
  , id_m0_servers :: [M0Host]
  , id_m0_globals :: M0Globals
#endif
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary InitialData
instance Hashable InitialData
instance FromJSON InitialData
instance ToJSON InitialData
