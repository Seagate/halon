{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StrictData        #-}
-- |
-- Module    : Helper.InitialData
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
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
import           Data.Word (Word8, Word32)
import qualified HA.Resources.Castor.Initial as CI
import           Helper.Environment (testListenName)
import           Mero.ConfC (ServiceType(..), Word128(..))
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
  , _id_data_units :: !Word32
  -- ^ Number of data units in a parity group -- N.
  , _id_parity_units :: !Word32
  -- ^ Number of parity units in a parity group -- K.
  , _id_allowed_failures :: [CI.Failures]
  -- ^ Value of 'pool_allowed_failures'.
  } deriving (Show, Eq)

-- | Defaults taken from
-- <http://es-gerrit.xyus.xyratex.com:8080/#/c/10913/1/modules/stx_halon/manifests/facts.pp>
defaultGlobals :: CI.M0Globals
defaultGlobals = CI.M0Globals
  { CI.m0_md_redundancy = 1
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

mkSvc :: Endpoint -> ServiceType -> CI.M0Service
mkSvc endpoint stype = CI.M0Service
  { CI.m0s_type       = stype
  , CI.m0s_endpoints  = [endpoint]
  , CI.m0s_pathfilter = Nothing
  }

initialData :: InitialDataSettings -> IO CI.InitialData
initialData InitialDataSettings{..}
  | (fromIntegral _id_servers * _id_drives) < fromIntegral pgWidth =
     fail $ "initialData: the given number of devices ("
         ++ show (fromIntegral _id_servers * _id_drives)
         ++ ") is smaller than data_units + 2 * parity_units ("
         ++ show pgWidth
         ++ ")."
  where
    pgWidth = _id_data_units + 2 * _id_parity_units
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
  , CI.id_m0_servers = hosts
  , CI.id_pools = [pool_0]
  , CI.id_profiles = [CI.M0Profile "prof-0" ["pool-0"]]
}
  where
    serverAddrs :: [(Word8, Word8, Word8, Word8)]
    serverAddrs = take (fromIntegral _id_servers)
                  -- Assign next IP to consecutive servers
                  $ iterate (\(x,y,z,w) -> (x,y,z,w + 1)) _id_host_ip

    hosts :: [CI.M0Host]
    hosts = fmap
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
                       { CI.m0d_wwn = "wwn" ++ show w ++ "_" ++ show j
                       , CI.m0d_serial = "serial" ++ show w ++ "_" ++ show j
                       , CI.m0d_bsize = 4
                       , CI.m0d_size = 64000
                       , CI.m0d_path = "/dev/loop" ++ show w ++ "_" ++ show j
                       , CI.m0d_slot = j
                       })
              [(1 :: Int) .. _id_drives]
          })
      serverAddrs

    deviceRefs = map (\CI.M0Device{..} -> CI.M0DeviceRef
            { CI.dr_wwn    = Just (T.pack m0d_wwn)
            , CI.dr_serial = Just (T.pack m0d_serial)
            , CI.dr_path   = Just (T.pack m0d_path)
            }) (concatMap CI.m0h_devices hosts)
    pool_0 = CI.M0Pool "pool-0" attrs _id_allowed_failures deviceRefs
    attrs = CI.PDClustAttrs0 { CI.pa0_data_units   = _id_data_units
                             , CI.pa0_parity_units = _id_parity_units
                             , CI.pa0_unit_size    = 4096
                             , CI.pa0_seed         = Word128 100 500
                             }

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
      , _id_data_units = 2
      , _id_parity_units = 1
      , _id_allowed_failures = [CI.Failures 0 0 0 0 1]
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
  { CI.m0p_endpoint = ep
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLHalon
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services = mkSvc ep <$> [CST_HA, CST_RMS]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }
  where
    ep = mkEP ifaddr 12345 34 101

-- | Create a confd 'CI.M0Process'
confdProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
             -> CI.M0Process
confdProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = ep
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0d 0
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services = mkSvc ep <$> [CST_CONFD, CST_RMS]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }
  where
    ep = mkEP ifaddr 12345 44 101

-- | Create an mds 'CI.M0Process'
mdsProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
           -> CI.M0Process
mdsProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = ep
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0d 0
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services = mkSvc ep <$> [CST_RMS, CST_MDS, CST_ADDB2]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }
  where
    ep = mkEP ifaddr 12345 41 201

-- | Create an IOS 'CI.M0Process'
iosProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
           -> CI.M0Process
iosProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = ep
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0d 1
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services = mkSvc ep <$> [ CST_RMS
                                   , CST_IOS
                                   , CST_SNS_REP
                                   , CST_SNS_REB
                                   , CST_ISCS
                                   , CST_ADDB2
                                   ]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }
  where
    ep = mkEP ifaddr 12345 41 401

-- | Create an M0T1FS 'CI.M0Process'
m0t1fsProcess :: (Word8, Word8, Word8, Word8) -- ^ IP of the host
              -> CI.M0Process
m0t1fsProcess ifaddr = CI.M0Process
  { CI.m0p_endpoint = ep
  , CI.m0p_mem_as = 1
  , CI.m0p_boot_level = CI.PLM0t1fs
  , CI.m0p_mem_rss = 1
  , CI.m0p_mem_stack = 1
  , CI.m0p_mem_memlock = 1
  , CI.m0p_cores = [1]
  , CI.m0p_services = [mkSvc ep CST_RMS]
  , CI.m0p_environment = Nothing
  , CI.m0p_multiplicity = Nothing
  }
  where
    ep = mkEP ifaddr 12345 41 401
