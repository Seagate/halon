module Helper.InitialData
  ( defaultGlobals
  , defaultInitialData
  , initialData
  ) where

import Mero.ConfC (ServiceParams(..), ServiceType(..))
import qualified HA.Resources.Castor.Initial as CI

import System.IO.Unsafe
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)

import Helper.Environment

defaultGlobals :: CI.M0Globals
defaultGlobals = CI.M0Globals {
    CI.m0_data_units = 8
  , CI.m0_parity_units = 2
  , CI.m0_md_redundancy = 2
  , CI.m0_failure_set_gen = CI.Preloaded 0 1 0
}

-- | Create initial data for use in tests.
initialData :: String -- ^ Hostname prefix (or hostname if only one host)
            -> String -- ^ Subnet (x.x.x)
            -> Int -- ^ Number of servers
            -> Int -- ^ Number of drives per server
            -> CI.M0Globals -- ^ Mero globals
            -> CI.InitialData
initialData _ _ s ds (CI.M0Globals d p _ _) | (s*ds) < fromIntegral (d +2*p) =
  error $ "initialData: the given number of devices ("
        ++ show (s*ds)
        ++ ") is smaller than 2 * parity_units + data_units (= "
        ++ show (d + 2*p)
        ++ ")."
initialData host_pfx ifaddr_pfx n_srv n_drv globs = CI.InitialData {
    CI.id_m0_globals = globs
  , CI.id_racks = [
      CI.Rack {
        CI.rack_idx = 1
      , CI.rack_enclosures = fmap
          (\i ->
            let
              host = case n_srv of
                1 -> host_pfx
                _ -> host_pfx ++ "_" ++ show i
              ifaddr = ifaddr_pfx ++ "." ++ show i
            in CI.Enclosure {
                  CI.enc_idx = i
                , CI.enc_id = "enclosure_" ++ show i
                , CI.enc_bmc = [CI.BMC (ifaddr_pfx ++ ".1") "admin" "admin"]
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
          [(2 :: Int) .. n_srv + 1]
      }
    ]
  , CI.id_m0_servers = fmap
      (\i -> let
          host = case n_srv of
            1 -> host_pfx
            _ -> host_pfx ++ "_" ++ show i
        in CI.M0Host {
            CI.m0h_fqdn = host
          , CI.m0h_processes = [
              CI.M0Process {
                CI.m0p_endpoint = host ++ "@tcp:12345:41:901"
              , CI.m0p_mem_as = 1
              , CI.m0p_boot_level = 0
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
              (\j -> CI.M0Device
                      ("wwn" ++ show i ++ show j)
                      ("serial" ++ show i ++ show j)
                      4 64000
                      ("/dev/loop" ++ show i ++ show j))
              [(1 :: Int) .. n_drv]
          })
      [(2 :: Int) .. n_srv + 1]
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
defaultInitialData :: CI.InitialData
defaultInitialData = initialData host "192.0.2" 1 12 defaultGlobals
  where host = unsafePerformIO $ do
          mhost <- fmap (fst . (span (/=':'))) <$> lookupEnv "TEST_LISTEN"
          case mhost of
            Nothing -> getLnetNid
            Just h  -> return h
