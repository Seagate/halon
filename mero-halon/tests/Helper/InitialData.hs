{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StrictData        #-}
-- |
-- Module    : Helper.InitialData
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
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
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           GHC.Word (Word8)
import qualified HA.Resources.Castor.Initial as CI
import           Helper.Environment (testListenName)
import           Mero.ConfC (ServiceType(..))
import           Mero.Lnet
import           Network.BSD (getHostName)
import           Text.Printf
import           Text.Read

-- | Configuration used in creation of 'CI.InitialData'. See 'initialData'.
data InitialDataSettings = InitialDataSettings
  { _id_hostname :: !T.Text
    -- ^ Hostname of the node. Can usually be obtained with @hostname@
    -- command. e.g. "devvm.seagate.com".
  , _id_host_ip :: !(Word8, Word8, Word8, Word8)
  -- ^ IP of the main host: the host running the tests and RC.
  -- e.g. "10.0.2.15" is provided as @(10,0,2,15)@.
  , _id_servers :: !Word8
  -- ^ Number of servers (i.e. 'CI.Enclosure's and 'CI.M0Host's) to
  -- generate. The naming scheme for enclosures in case @'_id_servers'
  -- > 1@ is "enclosure_i" where @i@ is the last octet of the
  -- enclosure's IP address. The IP address is constructed from
  -- '_id_host_ip', increasing the last octet for each new enclosure,
  -- allowing for overflow. Naming scheme for 'CI.M0Host's is
  -- @'_id_hostname'_i@.
  , _id_drives :: !Int
  -- ^ Number of drives __per enclosure__ to insert into the data.
  , _id_globals :: !CI.M0Globals
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

-- | Helper to make Endpoints from an IP
mkEP :: (Word8, Word8, Word8, Word8)
     -> Int -- ^ Process
     -> Int -- ^ portal_number
     -> Int -- ^ transfer_machine_id
     -> Endpoint
mkEP ip proc port tmid = Endpoint {
    network_id = IPNet (T.pack $ showIP ip) TCP
  , process_id = proc
  , portal_number = port
  , transfer_machine_id = tmid
  }

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
  , CI.id_sites = [
      CI.Site {
        CI.site_idx = 1
      , CI.site_racks = [
          CI.Rack {
            CI.rack_idx = 1
          , CI.rack_enclosures = fmap
              (\ifaddr@(x,y,z,w) ->
                let host = if _id_servers > 1
                           then _id_hostname <> "_" <> T.pack (show w)
                           else _id_hostname
                    ifaddrBMC = showIP (x, y, z + 10, w)
                in CI.Enclosure {
                      CI.enc_idx = fromIntegral w
                    , CI.enc_id = "enclosure_" ++ show w
                    , CI.enc_bmc = [CI.BMC ifaddrBMC "admin" "admin"]
                    , CI.enc_hosts = [
                        CI.Host {
                          CI.h_fqdn = host
                        , CI.h_halon = Just $ CI.HalonSettings {
                            CI._hs_address = showIP ifaddr ++ ":9000"
                          , CI._hs_roles = []
                          }
                        }
                      ]
                    })
              serverAddrs
          }
        ]
      }
    ]
  , CI.id_m0_servers = fmap
      (\ifaddr@(_,_,_,w) ->
         let host = if _id_servers > 1
                    then _id_hostname <> "_" <> T.pack (show w)
                    else _id_hostname
        in CI.M0Host {
            CI.m0h_fqdn = host
          , CI.m0h_processes = map ($ ifaddr)
              [haProcess, confdProcess, mdsProcess, iosProcess, m0t1fsProcess]
          , CI.m0h_devices = fmap
              (\j -> CI.M0Device
                      ("wwn" ++ show w ++ "_" ++ show j)
                      ("serial" ++ show w ++ "_" ++ show j)
                      4 64000
                      ("/dev/loop" ++ show w ++ "_" ++ show j)
                      j)
              [(1 :: Int) .. _id_drives]
          })
      serverAddrs
  , CI.id_pools = []
  , CI.id_profiles = []
}
  where
    serverAddrs :: [(Word8, Word8, Word8, Word8)]
    serverAddrs = take (fromIntegral _id_servers)
                  -- Assign next IP to consecutive servers
                  $ iterate (\(x,y,z,w) -> (x,y,z,w + 1)) _id_host_ip

-- | Pre-populated 'InitialDataSettings'.
defaultInitialDataSettings :: IO InitialDataSettings
defaultInitialDataSettings = do
  host <- T.pack <$> getHostName
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

-- * Processes

-- | Create halon 'CI.M0Process'.
haProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
             -> CI.M0Process
haProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = mkEP ifaddr 12345 34 101
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLHalon
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services =
    [ CI.M0Service
      { CI.m0s_type = CST_HA
      , CI.m0s_endpoints = [mkEP ifaddr 12345 34 101]
      , CI.m0s_pathfilter = Nothing }
    , CI.M0Service
      { CI.m0s_type = CST_RMS
      , CI.m0s_endpoints = [mkEP ifaddr 12345 34 101]
      , CI.m0s_pathfilter = Nothing }
    ]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }

-- | Create a confd 'CI.M0Process'
confdProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
             -> CI.M0Process
confdProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = mkEP ifaddr 12345 44 101
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0d 0
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services =
    [ CI.M0Service
        { CI.m0s_type = CST_CONFD
        , CI.m0s_endpoints = [mkEP ifaddr 12345 44 101]
        , CI.m0s_pathfilter = Nothing }
    , CI.M0Service
        { CI.m0s_type = CST_RMS
        , CI.m0s_endpoints = [mkEP ifaddr 12345 44 101]
        , CI.m0s_pathfilter = Nothing }
    ]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }

-- | Create an mds 'CI.M0Process'
mdsProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
           -> CI.M0Process
mdsProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = mkEP ifaddr 12345 41 201
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0d 0
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services =
    [ CI.M0Service
        { CI.m0s_type = CST_RMS
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 201]
        , CI.m0s_pathfilter = Nothing }
    , CI.M0Service
        { CI.m0s_type = CST_MDS
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 201]
        , CI.m0s_pathfilter = Nothing }
    , CI.M0Service
        { CI.m0s_type = CST_ADDB2
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 201]
        , CI.m0s_pathfilter = Nothing }
    ]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }

-- | Create an IOS 'CI.M0Process'
iosProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
           -> CI.M0Process
iosProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = mkEP ifaddr 12345 41 401
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0d 1
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services =
    [ CI.M0Service
        { CI.m0s_type = CST_RMS
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 401]
        , CI.m0s_pathfilter = Nothing }
    , CI.M0Service
        { CI.m0s_type = CST_IOS
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 401]
        , CI.m0s_pathfilter = Nothing }
    , CI.M0Service
        { CI.m0s_type = CST_SNS_REP
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 401]
        , CI.m0s_pathfilter = Nothing }
            , CI.M0Service
        { CI.m0s_type = CST_SNS_REB
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 401]
        , CI.m0s_pathfilter = Nothing }
    , CI.M0Service
        { CI.m0s_type = CST_ADDB2
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 401]
        , CI.m0s_pathfilter = Nothing }
    ]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }


-- | Create an M0T1FS 'CI.M0Process'
m0t1fsProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
           -> CI.M0Process
m0t1fsProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = mkEP ifaddr 12345 41 401
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0t1fs
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services =
    [ CI.M0Service
        { CI.m0s_type = CST_RMS
        , CI.m0s_endpoints = [mkEP ifaddr 12345 41 401]
        , CI.m0s_pathfilter = Nothing }
    ]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }
