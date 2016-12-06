{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE RecordWildCards #-}
-- |
-- Module    : Helper.InitialData
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module containing configurable 'CI.InitialData' used throughout
-- tests.
module Helper.InitialData
  ( defaultGlobals
  , defaultInitialData
  , defaultInitialDataSettings
  , initialData
  , InitialDataSettings(..)
  ) where

import           Data.List.Split (splitOn)
import           GHC.Word (Word8)
import qualified HA.Resources.Castor.Initial as CI
import           Helper.Environment (testListenName)
import           Mero.ConfC (ServiceParams(..), ServiceType(..))
import           Network.BSD (getHostName)
import           Text.Printf
import           Text.Read

-- | Configuration used in creation of 'CI.InitialData'. See 'initialData'.
data InitialDataSettings = InitialDataSettings
  { _id_hostname :: String
    -- ^ Hostname of the node. Can usually be obtained with @hostname@
    -- command. e.g. "devvm.seagate.com".
  , _id_host_ip :: (Word8, Word8, Word8, Word8)
  -- ^ IP of the main host: the host running the tests and RC.
  -- e.g. "10.0.2.15" is provided as @(10,0,2,15)@.
  , _id_servers :: Word8
  -- ^ Number of servers (i.e. 'CI.Enclosure's and 'CI.M0Host's) to
  -- generate. The naming scheme for enclosures in case @'_id_servers'
  -- > 1@ is "enclosure_i" where @i@ is the last octet of the
  -- enclosure's IP address. The IP address is constructed from
  -- '_id_host_ip', increasing the last octet for each new enclosure,
  -- allowing for overflow. Naming scheme for 'CI.M0Host's is
  -- @'_id_hostname'_i@.
  , _id_drives :: Int
  -- ^ Number of drives __per enclosure__ to insert into the data.
  , _id_globals :: CI.M0Globals
  -- ^ Various global settings usually provided by the provisioner.
  -- See 'defaultGlobals'.
  } deriving (Show, Eq)

-- | Defaults taken from
-- <http://es-gerrit.xyus.xyratex.com:8080/#/c/10913/1/modules/stx_halon/manifests/facts.pp>
defaultGlobals :: CI.M0Globals
defaultGlobals = CI.M0Globals {
    CI.m0_data_units = 8
  , CI.m0_parity_units = 2
  , CI.m0_md_redundancy = 1
  , CI.m0_failure_set_gen = CI.Preloaded 0 0 1
  , CI.m0_be_ios_seg_size = Nothing
  , CI.m0_be_log_size = Nothing
  , CI.m0_be_seg_size = Nothing
  , CI.m0_be_tx_payload_size_max = Nothing
  , CI.m0_be_tx_reg_nr_max = Nothing
  , CI.m0_be_tx_reg_size_max = Nothing
  , CI.m0_be_txgr_freeze_timeout_max = Nothing
  , CI.m0_be_txgr_freeze_timeout_min = Nothing
  , CI.m0_be_txgr_payload_size_max = Nothing
  , CI.m0_be_txgr_reg_nr_max = Nothing
  , CI.m0_be_txgr_reg_size_max = Nothing
  , CI.m0_be_txgr_tx_nr_max = Nothing
  , CI.m0_block_size = Nothing
  , CI.m0_min_rpc_recvq_len = Nothing
}

-- | Helper for IP addresses formatted as a quadruple of 'Word8's.
showIP :: (Word8, Word8, Word8, Word8) -> String
showIP (x,y,z,w) = printf "%d.%d.%d.%d" x y z w

initialData :: InitialDataSettings -> IO CI.InitialData
initialData InitialDataSettings{..}
  | (fromIntegral _id_servers * _id_drives) < fromIntegral (d + 2 * p) =
     fail $ "initialData: the given number of devices ("
         ++ show (fromIntegral _id_servers * _id_drives)
         ++ ") is smaller than 2 * parity_units + data_units (= "
         ++ show (d + 2 * p)
         ++ ")."
  where
    d = CI.m0_data_units _id_globals
    p = CI.m0_parity_units _id_globals
initialData InitialDataSettings{..} = return $ CI.InitialData {
    CI.id_m0_globals = _id_globals
  , CI.id_racks = [
      CI.Rack {
        CI.rack_idx = 1
      , CI.rack_enclosures = fmap
          (\i ->
            let host = if _id_servers > 1
                       then _id_hostname ++ "_" ++ show i
                       else _id_hostname
                ifaddr = (\(x,y,z,_) -> showIP (x, y, z, i)) _id_host_ip
                ifaddrBMC = (\(x,y,z,_) -> showIP (x, y, z + 10, i)) _id_host_ip
            in CI.Enclosure {
                  CI.enc_idx = fromIntegral i
                , CI.enc_id = "enclosure_" ++ show i
                , CI.enc_bmc = [CI.BMC ifaddrBMC "admin" "admin"]
                , CI.enc_hosts = [
                    CI.Host {
                      CI.h_fqdn = host
                    , CI.h_memsize = 4096
                    , CI.h_cpucount = 8
                    , CI.h_interfaces = [
                        CI.Interface {
                          CI.if_macAddress = "10-00-00-00-00"
                        , CI.if_network = CI.Data
                        , CI.if_ipAddrs = [ifaddr]
                        }
                      ]
                    , CI.h_halon = Just $ CI.HalonSettings {
                        CI._hs_address = ifaddr ++ ":9000"
                      , CI._hs_roles = []
                      }
                    }
                  ]
                })
          (take (fromIntegral _id_servers) $ iterate (+ 1) _id_servers)
      }
    ]
  , CI.id_m0_servers = fmap
      (\i -> let host = if _id_servers > 1
                        then _id_hostname ++ "_" ++ show i
                        else _id_hostname
                 ifaddr = (\(x,y,z,_) -> showIP (x, y, z, i)) _id_host_ip
        in CI.M0Host {
            CI.m0h_fqdn = host
          , CI.m0h_processes = [
              CI.M0Process {
                CI.m0p_endpoint = ifaddr ++ "@tcp:12345:41:901"
              , CI.m0p_mem_as = 1
              , CI.m0p_boot_level = 1
              , CI.m0p_mem_rss = 1
              , CI.m0p_mem_stack = 1
              , CI.m0p_mem_memlock = 1
              , CI.m0p_cores = [1]
              , CI.m0p_services = [
                  CI.M0Service {
                    CI.m0s_type = CST_MGS
                  , CI.m0s_endpoints = [ifaddr ++ "@tcp:12345:44:101"]
                  , CI.m0s_params = SPConfDBPath "/var/mero/confd"
                  , CI.m0s_pathfilter = Nothing
                  }
                , CI.M0Service {
                    CI.m0s_type = CST_RMS
                  , CI.m0s_endpoints = [ifaddr ++ "@tcp:12345:41:301"]
                  , CI.m0s_params = SPUnused
                  , CI.m0s_pathfilter = Nothing
                    }
                , CI.M0Service {
                    CI.m0s_type = CST_MDS
                  , CI.m0s_endpoints = [ifaddr ++ "@tcp:12345:41:201"]
                  , CI.m0s_params = SPUnused
                  , CI.m0s_pathfilter = Nothing
                  }
                , CI.M0Service {
                    CI.m0s_type = CST_IOS
                  , CI.m0s_endpoints = [ifaddr ++ "@tcp:12345:41:401"]
                  , CI.m0s_params = SPUnused
                  , CI.m0s_pathfilter = Nothing
                  }
                ]
              }
            ]
          , CI.m0h_devices = fmap
              (\j -> CI.M0Device
                      ("wwn" ++ show i ++ show j)
                      ("serial" ++ show i ++ show j)
                      4 64000
                      ("/dev/loop" ++ show i ++ show j))
              [(1 :: Int) .. _id_drives]
          })
      (take (fromIntegral _id_servers) $ iterate (+ 1) _id_servers)
}

-- | Pre-populated 'InitialDataSettings'.
defaultInitialDataSettings :: IO InitialDataSettings
defaultInitialDataSettings = do
  host <- getHostName
  traverse readMaybe . splitOn "." <$> testListenName >>= \case
    Just [x,y,z,w] -> return $ InitialDataSettings
      { _id_hostname = host
      , _id_host_ip = (x,y,z,w)
      , _id_servers = 1
      , _id_drives = 12
      , _id_globals = defaultGlobals
      }
    r -> fail $ "Could not obtain host IP for initial data: " ++ show r

-- | Default initial data used through-out tests. To generate custom
-- data, either use 'initialData' with custom 'InitialDataSettings' or
-- work directly on modifying 'CI.InitialData' if you have already
-- produced some.
defaultInitialData :: IO CI.InitialData
defaultInitialData = defaultInitialDataSettings >>= initialData
