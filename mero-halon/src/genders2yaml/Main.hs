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

import Control.Monad
  ( filterM
  , join
  )

import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import Data.Binary (Binary)
import qualified Data.ByteString.Char8 as BS
import Database.Genders
import qualified Data.HashMap.Lazy as M
import Data.List (isPrefixOf, nub)
import Data.Maybe (catMaybes, fromJust, maybeToList)
import qualified Data.Vector as V
import Data.Word (Word64)
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
makeInitialData :: DB -> [(String, Devices)] -> CI.InitialWithRoles
makeInitialData db devs = CI.InitialWithRoles {
    CI._rolesinit_id_m0_globals = CI.M0Globals {
      CI.m0_data_units = 2
    , CI.m0_parity_units = 1
    , CI.m0_md_redundancy = 2
    , CI.m0_failure_set_gen = CI.Dynamic
    }
  , CI._rolesinit_id_racks = [
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
  , CI._rolesinit_id_m0_servers = fmap
      (\host -> let
          attrs = attributesByNode host db
          svcs = maybe [] id
            . fmap (BS.split ';')
            . lookup "m0_services"
            $ attrs
          -- Our default roles expect some host attributes to be
          -- pre-defined. Create them here.
          lnid = fromJust . fmap BS.unpack $ lookup "m0_lnet_nid" attrs
          A.Object hostInfo = A.object [
                                "host_mem" A..= (1 :: Word64)
                              , "host_mem_rss" A..= (1 :: Word64)
                              , "host_mem_stack" A..= (1 :: Word64)
                              , "host_mem_memlock" A..= (1 :: Word64)
                              , "host_cores" A..= [(1 :: Word64)]
                              , "lnid" A..= lnid
                              ]

          uh = CI.UnexpandedHost {
                 CI._uhost_m0h_fqdn = BS.unpack host
               , CI._uhost_m0h_roles = fmap (\s -> CI.RoleSpec {
                   CI._rolespec_name = normaliseRole $ BS.unpack s
                 , CI._rolespec_overrides = Nothing }) svcs
               , CI._uhost_m0h_devices = fmap mkDevice . nub . join
                                       . fmap (unDevices . snd) $ devs
               }
        in (uh, (\(A.Object obj) -> obj `M.union` hostInfo) $ A.toJSON uh)

      )
      (V.toList $ nodes db)
    }

normaliseRole :: CI.RoleName -> CI.RoleName
normaliseRole x | "ios" `isPrefixOf` x = "ios"
                | otherwise = x

mkDevice :: Device -> CI.M0Device
mkDevice (Device i fp) = CI.M0Device {
    CI.m0d_wwn = "wwn-" ++ show i
  , CI.m0d_serial = "serial-" ++ show i
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
