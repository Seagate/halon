module Helper.InitialData
  ( initialData
  , initialDataAddr
  ) where

import Mero.ConfC (ServiceParams(..), ServiceType(..))
import qualified HA.Resources.Castor.Initial as CI

import System.IO.Unsafe
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)

import Helper.Environment

initialDataAddr :: String -> String -> Int -> CI.InitialData
initialDataAddr host ifaddr n = CI.InitialData {
  CI.id_racks = [
    CI.Rack {
      CI.rack_idx = 1
    , CI.rack_enclosures = [
        CI.Enclosure {
          CI.enc_idx = 1
        , CI.enc_id = "enclosure1"
        , CI.enc_bmc = [CI.BMC host "admin" "admin"]
        , CI.enc_hosts = [
            CI.Host {
              CI.h_fqdn = systemHostname
            , CI.h_memsize = 4096
            , CI.h_cpucount = 8
            , CI.h_interfaces = [
                CI.Interface {
                  CI.if_macAddress = "10-00-00-00-00"
                , CI.if_network = CI.Data
                , CI.if_ipAddrs = [ifaddr]
                }
              ]
            }
          ]
        }
      ]
    }
  ]
, CI.id_m0_globals = CI.M0Globals {
    CI.m0_datadir = "/var/mero"
  , CI.m0_t1fs_mount = "/mnt/mero"
  , CI.m0_data_units = 8
  , CI.m0_parity_units = 2
  , CI.m0_pool_width = 16
  , CI.m0_max_rpc_msg_size = 65536
  , CI.m0_uuid = "096051ac-b79b-4045-a70b-1141ca4e4de1"
  , CI.m0_min_rpc_recvq_len = 16
  , CI.m0_lnet_nid = "auto"
  , CI.m0_be_segment_size = 536870912
  , CI.m0_md_redundancy = 2
  , CI.m0_failure_set_gen = CI.Preloaded 0 1 0
  }
, CI.id_m0_servers = [
    CI.M0Host {
      CI.m0h_fqdn = systemHostname
    , CI.m0h_processes = [ 
        CI.M0Process { 
          CI.m0p_endpoint = host ++ "@tcp:12345:41:901"
        , CI.m0p_mem_as = 1
        , CI.m0p_mem_rss = 1
        , CI.m0p_mem_stack = 1
        , CI.m0p_mem_memlock = 1
        , CI.m0p_cores = [1]
        , CI.m0p_services = [
            CI.M0Service {
              CI.m0s_type = CST_MGS
            , CI.m0s_endpoints = [mgsEndpoint host]
            , CI.m0s_params = SPConfDBPath "/var/mero/confd"
            }
          , CI.M0Service {
              CI.m0s_type = CST_RMS
            , CI.m0s_endpoints = [rmsEndpoint host]
            , CI.m0s_params = SPUnused
              }
          , CI.M0Service {
              CI.m0s_type = CST_MDS
            , CI.m0s_endpoints = [mdsEndpoint host]
            , CI.m0s_params = SPUnused
            }
          , CI.M0Service {
              CI.m0s_type = CST_IOS
            , CI.m0s_endpoints = [iosEndpoint host]
            , CI.m0s_params = SPUnused
            }
          ]
        }
      ]
    , CI.m0h_devices = fmap
        (\i -> CI.M0Device ("wwn" ++ show i) 4 64000 ("/dev/loop" ++ show i))
        [(1 :: Int) .. n]
    }
  ]
}

mgsEndpoint, rmsEndpoint, mdsEndpoint, iosEndpoint :: String  -> String
mgsEndpoint host = unsafePerformIO $
  fromMaybe (host ++ "@tcp:12345:44:101") <$> lookupEnv confdEndpoint 
rmsEndpoint host = unsafePerformIO $
  fromMaybe (host ++ "@tcp:12345:41:301") <$> lookupEnv confdEndpoint 
mdsEndpoint host = unsafePerformIO $
  fromMaybe (host ++ "@tcp:12345:41:201") <$> lookupEnv confdEndpoint 
iosEndpoint host = unsafePerformIO $
  fromMaybe (host ++ "@tcp:12345:41:401") <$> lookupEnv confdEndpoint 

-- | Sample initial data for test purposes
initialData :: CI.InitialData
initialData = initialDataAddr host host 8
  where host = unsafePerformIO $ do
          mhost <- fmap (fst . (span (/=':'))) <$> lookupEnv "TEST_LISTEN"
          case mhost of
            Nothing -> getLnetNid
            Just h  -> return h
