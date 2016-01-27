{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
-- |
-- Utility for parsing a Mero genders file and generating a suitable Yaml
-- file for use by Halon.
-- This is a transitional utility intended to bridge the gap between the
-- current genders-based approach and provisioner generated Yaml files.

import Prelude hiding (lookup)

import qualified HA.Resources.Castor.Initial as CI

import Mero.ConfC (ServiceParams(..), ServiceType(..))

import Control.Monad
  ( filterM
  , join
  )

import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import Data.Binary (Binary)
import qualified Data.ByteString.Char8 as BS
import Database.Genders
import Data.List (isPrefixOf, nub)
import Data.Maybe (catMaybes, fromJust, maybeToList)
import qualified Data.Vector as V
import Data.Yaml

import GHC.Generics (Generic)

import System.Directory
  ( doesFileExist
  , listDirectory
  )
import System.Environment
  ( getArgs
  , getProgName
  )
import System.FilePath
  ( (</>) )
import System.IO
  ( hPutStrLn
  , stderr
  )

data Device = Device
    { _d_id :: Integer
    , _d_filename :: String
    }
  deriving (Eq, Show, Generic)

deviceJSONOptions :: A.Options
deviceJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_d_" :: String)) }

instance Binary Device
instance FromJSON Device where
  parseJSON = A.genericParseJSON deviceJSONOptions

newtype Devices = Devices { unDevices :: [Device] }
  deriving (Binary, Eq, Show, Generic)

instance FromJSON Devices where
  parseJSON (Object v) = Devices <$> v.: "Device"
  parseJSON _ = error "Can't parse Devices from Yaml"

main :: IO ()
main = getArgs >>= \case
  [x] -> do
    db <- readDB x
    BS.putStrLn . encode $ makeInitialData db []
  [x, y] -> do
    db <- readDB x
    devs <- readDevsFromDir y
    BS.putStrLn . encode $ makeInitialData db devs
  _ -> getProgName >>= \name ->
        hPutStrLn stderr $ "Usage: " ++ name ++ " <genders_file> "
                                     ++ "[<disks_conf_dir>]"

-- | Make initial data using details from the genders file
makeInitialData :: DB -> [(String, Devices)] -> CI.InitialData
makeInitialData db devs = CI.InitialData {
    CI.id_m0_globals = CI.M0Globals {
      CI.m0_data_units = 2
    , CI.m0_parity_units = 1
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
          , CI.m0h_devices = fmap mkDevice . nub . join
                              . fmap (unDevices . snd) $ devs
          })
      (V.toList $ nodes db)
    }

mkDevice :: Device -> CI.M0Device
mkDevice (Device i fp) = CI.M0Device {
    CI.m0d_wwn = "wwn-" ++ show i
  , CI.m0d_bsize = 4096
  , CI.m0d_size = 8192
  , CI.m0d_path = fp
}

readDevsFromDir :: FilePath -> IO [(String, Devices)]
readDevsFromDir dir = do
    files <- filter (isPrefixOf prefix)
              <$> (filterM (doesFileExist . (dir </>))
              =<< listDirectory dir)
    return . catMaybes =<< mapM readDevs files
  where
    prefix = "disks-"
    readDevs file = let
        name = takeWhile (/= '.') . drop (length prefix) $ file
      in decodeFile (dir </> file) >>= return . fmap (name,)

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
                  , CI.m0s_endpoints = maybeToList $ ep CST_MGS
                  , CI.m0s_params = SPConfDBPath "/var/mero/confd"
                  }
                , CI.M0Service {
                    CI.m0s_type = CST_RMS
                  , CI.m0s_endpoints = maybeToList $ ep CST_MDS
                  , CI.m0s_params = SPUnused
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
                  , CI.m0s_endpoints = maybeToList $ ep CST_MDS
                  , CI.m0s_params = SPUnused
                  }
                ]
              }
    "ha" -> Just $ CI.M0Process {
                CI.m0p_endpoint = fromJust $ ep CST_HA
              , CI.m0p_mem_as = 1
              , CI.m0p_mem_rss = 1
              , CI.m0p_mem_stack = 1
              , CI.m0p_mem_memlock = 1
              , CI.m0p_cores = [1]
              , CI.m0p_services = [
                  CI.M0Service {
                    CI.m0s_type = CST_HA
                  , CI.m0s_endpoints = maybeToList $ ep CST_HA
                  , CI.m0s_params = SPUnused
                  }
                ]
              }
    x | "ios" `BS.isPrefixOf` x -> Just $ CI.M0Process {
                CI.m0p_endpoint = fromJust $ ep CST_IOS
              , CI.m0p_mem_as = 1
              , CI.m0p_mem_rss = 1
              , CI.m0p_mem_stack = 1
              , CI.m0p_mem_memlock = 1
              , CI.m0p_cores = [1]
              , CI.m0p_services = [
                  CI.M0Service {
                    CI.m0s_type = CST_IOS
                  , CI.m0s_endpoints = maybeToList $ ep CST_IOS
                  , CI.m0s_params = SPUnused
                  }
                , CI.M0Service {
                    CI.m0s_type = CST_RMS
                  , CI.m0s_endpoints = maybeToList $ ep CST_IOS
                  , CI.m0s_params = SPUnused
                  }
                ]
                ]
              }
    _ -> Nothing

-- | Default endpoints for services in initscripts.
epAddress :: ServiceType -> String
epAddress CST_MGS = ":12345:44:101"
epAddress CST_RMS = ":12345:41:301"
epAddress CST_MDS = ":12345:41:201"
epAddress CST_IOS = ":12345:41:401"
epAddress CST_HA  = ":12345:34:101"
epAddress _       = ":12345:41:901"
