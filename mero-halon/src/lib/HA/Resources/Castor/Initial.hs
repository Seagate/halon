{-# LANGUAGE CPP                        #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Initial resource load for Castor cluster.
-- This module should be imported qualified.

module HA.Resources.Castor.Initial where

#ifdef USE_MERO
import Mero.ConfC (ServiceParams)
#endif

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

data Interface = Interface {
    if_macAddress :: String
  , if_network :: Network
  , if_ipAddrs :: [String]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Interface
instance Hashable Interface

data Host = Host {
    h_fqdn :: String
  , h_interfaces :: [Interface]
  , h_memsize :: Word32 -- ^ Memory in MB
  , h_cpucount :: Word32 -- ^ Number of CPUs
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Host
instance Hashable Host

data BMC = BMC {
    bmc_addr :: String
  , bmc_user :: String
  , bmc_pass :: String
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary BMC
instance Hashable BMC

data Enclosure = Enclosure {
    enc_idx :: Int
  , enc_id :: String
  , enc_bmc :: BMC
  , enc_hosts :: [Host]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Enclosure
instance Hashable Enclosure

data Rack = Rack {
    rack_idx :: Int
  , rack_enclosures :: [Enclosure]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Rack
instance Hashable Rack

#ifdef USE_MERO

data M0Globals = M0Globals {
    m0_datadir :: String
  , m0_t1fs_mount :: String
  , m0g_data_units :: Word32 -- ^ As in genders
  , m0g_parity_units :: Word32  -- ^ As in genders
  , m0g_pool_width :: Word32 -- ^ As in genders
  , m0_max_rpc_msg_size :: Word32 -- ^ As in genders
  , m0_uuid :: String
  , m0_min_rpc_recvq_len :: Word32
  , m0_lnet_nid :: String
  , m0_be_segment_size :: Word32
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Globals
instance Hashable M0Globals

data M0Device = M0Device {
    m0d_wwn :: String
  , m0d_bsize :: Word32 -- ^ Block size
  , m0d_size :: Word64 -- ^ Size of disk (in MB)
  , m0d_path :: String -- ^ Path to the device (e.g. /dev/disk...)
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Device
instance Hashable M0Device

data M0Host = M0Host {
    m0h_fqdn :: String -- ^ FQDN of host this server is running on
  , m0h_mem_as :: Word64
  , m0h_mem_rss :: Word64
  , m0h_mem_stack :: Word64
  , m0h_mem_memlock :: Word64
  , m0h_cores :: Word32
    -- ^ Treated as a bitmap of length (no_cpu) indicating which CPUs to use
  , m0h_services :: [M0Service]
  , m0h_devices :: [M0Device]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Host
instance Hashable M0Host

data M0Service = M0Service {
    m0s_type :: String -- ^ e.g. ioservice, haservice
  , m0s_endpoints :: [String]
  , m0s_params :: ServiceParams
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Service
instance Hashable M0Service

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
