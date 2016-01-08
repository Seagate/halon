{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Utility for parsing a Mero genders file and generating a suitable Yaml
-- file for use by Halon.
-- This is a transitional utility intended to bridge the gap between the
-- current genders-based approach and provisioner generated Yaml files.

import Prelude hiding (lookup)

import qualified HA.Resources.Castor.Initial as CI

import Mero.ConfC (ServiceParams(..), ServiceType(..))

import qualified Data.ByteString.Char8 as BS
import Database.Genders
import Data.Maybe (catMaybes, fromJust, maybeToList)
import qualified Data.Vector as V
import Data.Yaml

import System.Environment
  ( getArgs
  , getProgName
  )
import System.IO
  ( hPutStrLn
  , stderr
  )

main :: IO ()
main = getArgs >>= \case
  [x] -> do
    db <- readDB x
    BS.putStrLn . encode $ makeInitialData db
  _ -> getProgName >>= \name ->
        hPutStrLn stderr $ "Usage: " ++ name ++ " <genders_file>"

-- | Make initial data using details from the genders file
makeInitialData :: DB -> CI.InitialData
makeInitialData db = CI.InitialData {
    CI.id_m0_globals = CI.M0Globals {
      CI.m0_datadir = "/var/mero"
    , CI.m0_t1fs_mount = "/mnt/mero"
    , CI.m0_data_units = 2
    , CI.m0_parity_units = 1
    , CI.m0_pool_width = 8
    , CI.m0_max_rpc_msg_size = 65536
    , CI.m0_uuid = "096051ac-b79b-4045-a70b-1141ca4e4de1"
    , CI.m0_min_rpc_recvq_len = 16
    , CI.m0_lnet_nid = "auto"
    , CI.m0_be_segment_size = 536870912
    , CI.m0_md_redundancy = 2
    , CI.m0_failure_set_gen = CI.Dynamic
    }
  , CI.id_racks = [
      CI.Rack {
        CI.rack_idx = 1
      , CI.rack_enclosures = [
          CI.Enclosure {
            CI.enc_idx = 1
          , CI.enc_id = "enclosure1"
          , CI.enc_bmc = [CI.BMC "bmc.enclosure1" "admin" "admin"]
          , CI.enc_hosts = fmap (\host ->
              CI.Host {
                CI.h_fqdn = BS.unpack host
              , CI.h_memsize = 4096
              , CI.h_cpucount = 8
              , CI.h_interfaces = [
                  CI.Interface {
                    CI.if_macAddress = "10-00-00-00-00"
                  , CI.if_network = CI.Data
                  , CI.if_ipAddrs = maybeToList
                      . fmap (BS.unpack . head . BS.split '@')
                      . lookup "m0_lnet_nid"
                      $ attributesByNode host db
                  }
                ]
              }
            )
            (V.toList $ nodes db)
          }
        ]
      }
    ]
  , CI.id_m0_servers = fmap
      (\host -> let
          attrs = attributesByNode host db
          svcs = maybe [] id
            . fmap (BS.split ';')
            . lookup "m0_services"
            $ attrs
        in
          CI.M0Host {
            CI.m0h_fqdn = BS.unpack host
          , CI.m0h_processes = catMaybes $ fmap (serviceProcess db host) svcs
          , CI.m0h_devices = []
          })
      (V.toList $ nodes db)
    }

-- | Take a named service from genders and convert it into a suitable
--   process.
serviceProcess :: DB
               -> BS.ByteString -- ^ Host
               -> BS.ByteString
               -> Maybe CI.M0Process
serviceProcess db host svcName = let
    attrs = attributesByNode host db
    lnet_nid = fmap BS.unpack $ lookup "m0_lnet_nid" attrs
    ep st = fmap (++ (epAddress st)) lnet_nid
  in case svcName of
    "confd" -> Just $ CI.M0Process {
                CI.m0p_endpoint = fromJust $ ep CST_MGS
              , CI.m0p_mem_as = 1
              , CI.m0p_mem_rss = 1
              , CI.m0p_mem_stack = 1
              , CI.m0p_mem_memlock = 1
              , CI.m0p_cores = [1]
              , CI.m0p_services = [
                  CI.M0Service {
                    CI.m0s_type = CST_MGS
                  , CI.m0s_endpoints = maybe [] (:[]) $ ep CST_MGS
                  , CI.m0s_params = SPConfDBPath "/var/mero/confd"
                  }
                ]
              }
    "mds" -> Just $ CI.M0Process {
                CI.m0p_endpoint = fromJust $ ep CST_MDS
              , CI.m0p_mem_as = 1
              , CI.m0p_mem_rss = 1
              , CI.m0p_mem_stack = 1
              , CI.m0p_mem_memlock = 1
              , CI.m0p_cores = [1]
              , CI.m0p_services = [
                  CI.M0Service {
                    CI.m0s_type = CST_MDS
                  , CI.m0s_endpoints = maybe [] (:[]) $ ep CST_MDS
                  , CI.m0s_params = SPUnused
                  }
                ]
              }
    _ -> Nothing

-- | Default endpoints for services in initscripts.
epAddress :: ServiceType -> String
epAddress CST_MGS = ":12345:44:101"
epAddress CST_RMS = ":12345:41:301"
epAddress CST_MDS = ":12345:41:201"
epAddress CST_IOS = ":12345:41:401"
epAddress _       = ":12345:41:901"
