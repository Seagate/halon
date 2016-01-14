module Helper.InitialData
  ( initialData
  , initialDataAddr
  , initialDataGen
  ) where

import Mero.ConfC (ServiceParams(..), ServiceType(..))
import qualified HA.Resources.Castor.Initial as CI

import System.IO.Unsafe
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)

import Helper.Environment

initialDataGen :: String -- ^ Hostname prefix
               -> String -- ^ Subnet (x.x.x)
               -> Int -- ^ Number of servers
               -> Int -- ^ Number of drives per server
               -> CI.FailureSetScheme -- ^ FS scheme
               -> CI.InitialData
initialDataGen host_pfx ifaddr_pfx n_srv n_drv scheme = CI.InitialData {
    CI.id_m0_globals = CI.M0Globals {
      CI.m0_data_units = 8
    , CI.m0_parity_units = 2
    , CI.m0_md_redundancy = 2
    , CI.m0_failure_set_gen = scheme
    }
  , CI.id_racks = [
      CI.Rack {
        CI.rack_idx = 1
      , CI.rack_enclosures = fmap
          (\i ->
            let
              host = host_pfx ++ "_" ++ show i
              ifaddr = ifaddr_pfx ++ "." ++ show i
            in CI.Enclosure {
                  CI.enc_idx = i
                , CI.enc_id = "enclosure_" ++ show i
                , CI.enc_bmc = [CI.BMC host "admin" "admin"]
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
                    }
                  ]
                })
          [(1 :: Int) .. n_srv]
      }
    ]
  , CI.id_m0_servers = fmap
      (\i -> let
          host = host_pfx ++ "_" ++ show i
        in CI.M0Host {
            CI.m0h_fqdn = host
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
              (\j -> CI.M0Device ("wwn" ++ show i ++ show j) 4 64000 ("/dev/loop" ++ show i ++ show j))
              [(1 :: Int) .. n_drv]
          })
      [(1 :: Int) .. n_srv]
}

initialDataAddr :: String -> String -> Int -> CI.InitialData
<<<<<<< HEAD
initialDataAddr _ _ n | n < 12 =
=======
initialDataAddr _host _ifaddr n | n < 12 =
>>>>>>> 4bc4368... Fix compilation warnings.
     error $ "initialDataAddr: the given number of devices (" ++ show n
             ++ ") is smaller than 2 * parity_units + data_units (= 12)."
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
    CI.m0_data_units = 8
  , CI.m0_parity_units = 2
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
initialData = initialDataAddr host host 12
  where host = unsafePerformIO $ do
          mhost <- fmap (fst . (span (/=':'))) <$> lookupEnv "TEST_LISTEN"
          case mhost of
            Nothing -> getLnetNid
            Just h  -> return h
