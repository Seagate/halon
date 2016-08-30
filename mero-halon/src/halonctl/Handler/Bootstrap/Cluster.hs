{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Script that is responsible for bootstrapping entire cluster.
module Handler.Bootstrap.Cluster
  ( bootstrap
  , schema
  , Config
  ) where

import qualified Handler.Service as Service
import           HA.EventQueue.Producer
import qualified Handler.Bootstrap.TrackingStation as Station
import qualified Handler.Bootstrap.Satellite as Satellite
import           HA.Resources.Castor.Initial as CI
import HA.RecoveryCoordinator.Events.Castor.Cluster
import           Lookup (conjureRemoteNodeId)

import qualified Options.Applicative as Opt
import qualified Options.Applicative.Types as Opt
import qualified Options.Applicative.Internal as Opt
import           Data.Defaultable (Defaultable(..), defaultable, fromDefault)

import Control.Distributed.Process
import Control.Lens
import Control.Monad (unless, when, void)
import Data.Bifunctor
import Data.Foldable (for_)
import Data.List (intercalate)
import Data.Monoid ((<>))
import Data.Typeable
import Data.Validation
import GHC.Generics (Generic)

import System.Exit

data Config = Config
  { configInitialData :: Defaultable FilePath
  , configRoles  :: Defaultable FilePath
  , configHalonRoles :: Defaultable FilePath
  , configDryRun :: Bool
  } deriving (Eq, Show, Ord, Generic, Typeable)

schema :: Opt.Parser Config
schema = let
    initial = defaultable "/etc/halon/halon_facts.yaml" . Opt.strOption
            $ Opt.long "facts"
            <> Opt.short 'f'
            <> Opt.help "Halon facts file"
            <> Opt.metavar "FILEPATH"
    roles = defaultable "/etc/halon/role_maps/prov.ede" . Opt.strOption
          $ Opt.long "roles"
         <> Opt.short 'r'
         <> Opt.help "Mero roles file used by halon"
         <> Opt.metavar "FILEPATH"
    halonRoles = defaultable "/etc/halon/halon_role_mappings" . Opt.strOption
          $ Opt.long "halonroles"
         <> Opt.short 's'
         <> Opt.help "Halon-specific roles file"
         <> Opt.metavar "FILEPATH"
    dry  = Opt.switch
          $ Opt.long "dry-run"
         <> Opt.short 'n'
         <> Opt.help "Do not actually start cluster, just log actions"
  in Config <$> initial <*> roles <*> halonRoles <*> dry

data ValidatedConfig = ValidatedConfig
      { vcTsConfig :: (String, Station.Config)  -- ^ Tracking station config and it's representation
      , vcSatConfig :: (String, Satellite.Config) -- ^ Satellite config and it's representation
      , vcHosts :: [(String, String, [HalonRole], [(String, Service.ServiceCmdOptions)])]
        -- ^ Addresses of hosts and their halon roles: @(fqdn, ip, roles, (servicestrings, parsedserviceconfs))@
      }

bootstrap :: Config -> Process ()
bootstrap Config{..} = do
  einitData <- liftIO $ CI.parseInitialData (fromDefault configInitialData)
                                            (fromDefault configRoles)
                                            (fromDefault configHalonRoles)
  case einitData of
    Left err -> liftIO . putStrLn $ "Failed to load initial data: " ++ show err
    Right (initialData, halonRoleObj) -> do
      -- Check services config files
      let validateTrackingStationCfg = (text,) <$> parseHelper Station.schema text
            where text = ""
          validateSatelliteCfg = (text,) <$> parseHelper Satellite.schema text
            where text = ""

      -- Check halon facts and get interseting info. Throw away hosts
      -- without halon roles.
      let ehosts = filter (\(_, _, hrs, _) -> not $ null hrs) <$> traverse unwrap hosts

          hosts :: [(Host, HalonSettings)]
          hosts = [ (h, hs) | r <- id_racks initialData
                            , enc <- rack_enclosures r
                            , h <- enc_hosts enc
                            , Just hs <- [h_halon h] ]

          unwrap (h, hs) = case mkHalonRoles halonRoleObj $ _hs_roles hs of
            Left err -> _Failure # ["Halon role failure for " ++ h_fqdn h ++ ": " ++ err]
            Right hRoles -> (\srvs -> (h_fqdn h, _hs_address hs, hRoles, srvs))
                            <$> parseSrvs hRoles

          parseSrvs = sequenceA . map parseSrv . concatMap _hc_h_services

          parseSrv str = case parseHelper Service.parseService str of
            Left e -> _Failure # ["Failure to parse service \"" ++ str ++ "\": " ++ show e]
            Right conf -> _Success # (str, conf)

      -- Create validated config
      let evalidatedConfig :: AccValidation [String] ValidatedConfig
          evalidatedConfig = ValidatedConfig
           <$> (first (\e -> ["Error when reading tracking station config:  " ++ show e])
                  validateTrackingStationCfg ^. from _Either)
           <*> (first (\e -> ["Error when reading satellite config: " ++ show e])
                  validateSatelliteCfg  ^. from _Either)
           <*>  ehosts

      -- run bootstrap
      case evalidatedConfig of
        AccFailure strs -> liftIO $ do
          putStrLn "Failed to validate settings: "
          mapM_ putStrLn strs
        AccSuccess ValidatedConfig{..} -> do
          when dry $ do
            out "#!/bin/sh"
            out "set -xe"

          let getRoles :: ([HalonRole] -> Bool) -> [String]
              getRoles p = map (\(_, ip, _, _) -> ip)
                           $ filter (\(_, _, roles, _) -> p roles) vcHosts

              -- no TS, some services
          let satellite_hosts = getRoles $ const True
              -- TS
              station_hosts = getRoles $ any (\(HalonRole _ ts _ ) -> ts)

          case null station_hosts of
            True -> liftIO $ putStrLn "No station hosts, can't do anything"
            False -> do
              bootstrapStation vcTsConfig station_hosts
              bootstrapSatellites vcSatConfig station_hosts satellite_hosts

              out "# Starting services"
              for_ vcHosts $ \(fqdn, ip, _, srvs) -> do
                unless (null srvs) . out $ "# Services for " ++ show fqdn
                for_ srvs $ \(str, conf) -> do
                  startService ip (str, conf) station_hosts

              loadInitialData station_hosts
                              initialData
                              (fromDefault configInitialData)
                              (fromDefault configRoles)
              startCluster station_hosts
              unless configDryRun $
                receiveTimeout step_delay [] >> return ()
  where
    dry = configDryRun
    out = liftIO . putStrLn
    step_delay    = 10000000

    startService :: String -> (String, Service.ServiceCmdOptions) -> [String] -> Process ()
    startService host (srvString, conf) stations
      | dry = do
          out $ "halonctl -l $IP:0 -a " ++ host
             ++ " service " ++ srv
      | otherwise = Service.service nodes conf
      where
        srv = srvString ++ " -t " ++ intercalate " -t " stations
        nodes = conjureRemoteNodeId <$> [host]

    -- Bootstrap all halon stations.
    bootstrapStation :: (String, Station.Config) -> [String] -> Process ()
    bootstrapStation (str, _) hosts | dry = do
       out "# Starting stations"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " hosts ++ " bootstrap station" ++ str
    bootstrapStation (_, conf) hosts = do
      Station.start nodes conf
      where
        nodes = conjureRemoteNodeId <$> hosts
    -- Bootstrap satellites
    bootstrapSatellites :: (String, Satellite.Config) -> [String] -> [String] -> Process ()
    bootstrapSatellites _ stations hosts | dry = do
       out "# Starting satellites"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " hosts
                                     ++ " bootstrap satellite -t "
                                     ++ intercalate " -t " stations
    bootstrapSatellites (_, cfg) st hosts = do
      Satellite.startSatellitesAsync conf nodes >>= \case
        [] -> return ()
        failures -> liftIO $ do
          putStrLn $ "nodeUp failed on following nodes: " ++ show failures
          exitFailure
       where
         nodes = conjureRemoteNodeId <$> hosts
         conf = cfg{Satellite.configTrackers=Configured st}

    loadInitialData satellites _ fn roles | dry = do
       out $ "# load intitial data"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " satellites
             ++ " cluster load -f " ++ fn ++ " -r " ++ roles
    loadInitialData satellites datum _ _ = do
        promulgateEQ eqnids datum >>= \pid -> withMonitor pid wait
        _ <- receiveTimeout step_delay []
        return ()
      where
        wait = void (expect :: Process ProcessMonitorNotification)
        eqnids = conjureRemoteNodeId <$> satellites

    startCluster stations | dry = do
       out $ "# Start cluster"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " stations
             ++ " cluster start"
    startCluster stations = do
        promulgateEQ stnodes ClusterStartRequest >>= flip withMonitor wait
      where
        stnodes = conjureRemoteNodeId <$> stations
        wait = void (expect :: Process ProcessMonitorNotification)
--
-- | Parse options.
parseHelper :: Opt.Parser a -> String -> Either Opt.ParseError a
parseHelper schm text = fst $
    Opt.runP (Opt.runParserFully Opt.SkipOpts schm t) Opt.defaultPrefs
  where t = words text
