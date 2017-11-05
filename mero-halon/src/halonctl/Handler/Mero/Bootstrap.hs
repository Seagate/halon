{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE StrictData       #-}
{-# LANGUAGE TupleSections    #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Module    : Handler.Mero.Bootstrap
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Script that is responsible for bootstrapping entire cluster.
module Handler.Mero.Bootstrap
  ( Options(..)
  , parser
  , run_XXX0
  ) where

import           Control.Distributed.Process
import           Control.Lens
import           Control.Monad (unless, when, void)
import           Data.Bifunctor
import           Data.Defaultable (Defaultable(..), defaultable, fromDefault)
import           Data.Foldable (for_)
import           Data.List (intercalate)
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import           Data.Proxy
import qualified Data.Text as T
import           Data.Typeable
import           Data.Validation
import           GHC.Generics (Generic)
import           HA.EventQueue
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import           HA.RecoveryCoordinator.RC.Events.Cluster
import qualified HA.Resources.Castor.Initial as CI
import qualified Handler.Halon.Node.Add as NodeAdd
import qualified Handler.Halon.Service as Service
import qualified Handler.Halon.Station as Station
import           Lookup (conjureRemoteNodeId)
import           Network.CEP (Published(..))
import qualified Options.Applicative as Opt
import qualified Options.Applicative.Internal as Opt
import qualified Options.Applicative.Types as Opt
import           System.Environment
import           System.Exit

data Options = Options
  { configInitialData :: Defaultable FilePath
  , configMeroRoles :: Defaultable FilePath
  , configHalonRoles :: Defaultable FilePath
  , configDryRun :: Bool
  , configVerbose :: Bool
  , configMkfsDone :: Bool
  } deriving (Eq, Show, Ord, Generic, Typeable)

parser :: Opt.Parser Options
parser = let
    initial = defaultable "/etc/halon/halon_facts.yaml" . Opt.strOption
            $ Opt.long "facts"
            <> Opt.short 'f'
            <> Opt.help "Halon facts file"
            <> Opt.metavar "FILEPATH"
    meroRoles = defaultable "/etc/halon/mero_role_mappings" . Opt.strOption
          $ Opt.long "roles" -- XXX TODO: rename to "mero-roles"
         <> Opt.short 'r'
         <> Opt.help "Mero roles file used by Halon"
         <> Opt.metavar "FILEPATH"
    halonRoles = defaultable "/etc/halon/halon_role_mappings" . Opt.strOption
          $ Opt.long "halonroles" -- XXX TODO: rename to "halon-roles"
         <> Opt.short 's'
         <> Opt.help "Halon-specific roles file"
         <> Opt.metavar "FILEPATH"
    dry = Opt.switch
          $ Opt.long "dry-run"
         <> Opt.short 'n'
         <> Opt.help "Do not actually start cluster, just log actions"
    verbose = Opt.switch
          $ Opt.long "verbose"
         <> Opt.short 'v'
         <> Opt.help "Verbose output"
    mkfs = Opt.switch
         $ Opt.long "mkfs-done"
         <> Opt.help "Do not run mkfs on a cluster."
  in Options <$> initial <*> meroRoles <*> halonRoles <*> dry <*> verbose <*> mkfs

data Host = Host
  { hFqdn :: T.Text
  , hIp :: String
  , hRoles :: [CI.HalonRole]
  , hSvcs :: [( String          -- service string
              , Service.Options -- parsed service config
              )]
  }

data ValidatedConfig = ValidatedConfig
  { vcTsConfig :: (String, Station.Options)
  -- ^ Tracking station config and it's representation.
  , vcSatConfig :: (String, NodeAdd.Options)
  -- ^ Satellite config and it's representation.
  , vcHosts :: [Host]
  }

mkValidatedConfig :: [CI.Rack_XXX0]
                  -> ([CI.RoleSpec] -> Either String [CI.HalonRole])
                  -> String -- ^ Tracking station options.
                  -> AccValidation [String] ValidatedConfig
mkValidatedConfig racks mkRoles stationOpts =
    ValidatedConfig
        <$> (firstErr "tracking station" validateTStationOpts ^. from _Either)
        <*> (firstErr "satellite" validateSatelliteOpts ^. from _Either)
        <*> ehosts
  where
    firstErr what = first $ \e ->
        ["Error when reading " ++ what ++ " config: " ++ showParseError e]

    validateTStationOpts :: Either Opt.ParseError (String, Station.Options)
    validateTStationOpts = let text = stationOpts
                           in (text,) <$> parseHelper Station.parser text

    validateSatelliteOpts :: Either Opt.ParseError (String, NodeAdd.Options)
    validateSatelliteOpts = let text = "" -- XXX Why bother parsing an empty
                                          -- string?
                            in (text,) <$> parseHelper NodeAdd.parser text

    hosts :: [(CI.Host_XXX0, CI.HalonSettings)]
    hosts = [ (h, hs) | rack <- racks
                      , enc <- CI.rack_enclosures_XXX0 rack
                      , h <- CI.enc_hosts_XXX0 enc
                      , Just hs <- [CI.h_halon_XXX0 h] ]

    ehosts :: AccValidation [String] [Host]
    ehosts = filter (not . null . hRoles) <$> traverse expandHost hosts

    expandHost :: (CI.Host, CI.HalonSettings) -> AccValidation [String] Host
    expandHost (h, hs) = case mkRoles (CI._hs_roles hs) of
        Left err -> _Failure # ["Halon role failure for "
                                ++ T.unpack (CI.h_fqdn_XXX0 h) ++ ": " ++ err]
        Right roles -> (\svcs -> Host { hFqdn = CI.h_fqdn_XXX0 h
                                      , hIp = CI._hs_address hs
                                      , hRoles = roles
                                      , hSvcs = svcs
                                      }
                        ) <$> parseSvcs roles

    parseSvcs :: [CI.HalonRole]
              -> AccValidation [String] [(String, Service.Options)]
    parseSvcs = sequenceA . map parseSvc . concatMap CI._hc_h_services

    parseSvc :: String -> AccValidation [String] (String, Service.Options)
    parseSvc str = case parseHelper Service.parser str of
        Left err -> _Failure # ["Failure to parse service \"" ++ str ++ "\": "
                              ++ showParseError err]
        Right conf -> _Success # (str, conf)

run_XXX0 :: Options -> Process ()
run_XXX0 Options{..} = do
  _einitData <- liftIO $ CI.parseInitialData "/tmp/new-facts_XXX.yaml"
                                            (fromDefault configRoles)
                                            (fromDefault configHalonRoles)
  liftIO . putStrLn $ "XXX " ++ case _einitData of
      Left err -> "**ERROR** " ++ show err
      Right (initData, _) -> show initData
  einitData <- liftIO $ CI.parseInitialData_XXX0 (fromDefault configInitialData)
                                            (fromDefault configMeroRoles)
                                            (fromDefault configHalonRoles)
  case einitData of
    Left err -> out $ "Failed to load initial data: " ++ show err
    Right (initialData, halonRoleObj) -> do
      stationOpts <- fmap (fromMaybe "") . liftIO
          $ lookupEnv "HALOND_STATION_OPTIONS"
      let evConfig = mkValidatedConfig (CI.id_racks_XXX0 initialData)
                                       (CI.mkHalonRoles halonRoleObj)
                                       stationOpts
      case evConfig of
        AccFailure strs -> liftIO $ do
          putStrLn "Failed to validate settings: "
          mapM_ putStrLn strs
        AccSuccess ValidatedConfig{..} -> do
          verbose "Halon facts"
          liftIO (readFile $ fromDefault configInitialData) >>= verbose
          verbose "Mero roles"
          liftIO (readFile $ fromDefault configMeroRoles) >>= verbose
          verbose "Halon roles"
          liftIO (readFile $ fromDefault configHalonRoles) >>= verbose

          when dry $ do
            out "#!/bin/sh"
            out "set -xe"

          let getIps :: ([CI.HalonRole] -> Bool) -> [String]
              getIps p = map hIp $ filter (p . hRoles) vcHosts

              station_hosts = getIps $ any CI._hc_h_bootstrap_station -- TS
              satellite_hosts = getIps $ const True -- no TS, some services

          if null station_hosts
            then out "No station hosts, can't do anything"
            else do
              bootstrapStation vcTsConfig station_hosts
              bootstrapSatellites vcSatConfig station_hosts satellite_hosts

              out "# Starting services"
              for_ vcHosts $ \Host{..} -> do
                unless (null hSvcs) . out $ "# Services for " ++ show hFqdn
                for_ hSvcs $ \svc -> startService hIp svc station_hosts

              loadInitialData station_hosts
                              initialData
                              (fromDefault configInitialData)
                              (fromDefault configMeroRoles)

              when configMkfsDone $ do
                if dry
                then out $ "halonctl -l $IP:0 mero mkfs-done --confirm "
                        ++ intercalate " -t " station_hosts
                else do
                  let stnodes = conjureRemoteNodeId <$> station_hosts
                  (schan, rchan) <- newChan
                  _ <- promulgateEQ stnodes (MarkProcessesBootstrapped schan)
                  void $ receiveWait [ matchChan rchan (const $ return ()) ]

              startCluster station_hosts
              unless dry $ receiveTimeout step_delay [] >> return ()
  where
    dry = configDryRun
    out = liftIO . putStrLn
    verbose = liftIO . if configVerbose then putStrLn else const (return ())
    step_delay = 10000000

    startService :: String -> (String, Service.Options) -> [String] -> Process ()
    startService host (svcString, conf) stations
      | dry =
          let svc = svcString ++ " -t " ++ intercalate " -t " stations
          in out $ "halonctl -l $IP:0 -a " ++ host ++ " halon service " ++ svc
      | otherwise = Service.service [conjureRemoteNodeId host] conf

    -- Bootstrap all halon stations.
    bootstrapStation :: (String, Station.Options) -> [String] -> Process ()
    bootstrapStation (str, _) hosts | dry = do
        out "# Starting stations"
        out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " hosts
            ++ " halon station" ++ str
    bootstrapStation (_, conf) hosts = do
        verbose $ "Starting stations: " ++ show hosts
        Station.start nodes conf
      where
        nodes = conjureRemoteNodeId <$> hosts

    -- Bootstrap satellites.
    bootstrapSatellites :: (String, NodeAdd.Options) -> [String] -> [String] -> Process ()
    bootstrapSatellites _ stations hosts | dry = do
        out "# Starting satellites"
        out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " hosts
            ++ " halon node add -t " ++ intercalate " -t " stations
    bootstrapSatellites (_, cfg) st hosts = do
        verbose $ "Starting satellites" ++ show hosts
        NodeAdd.run nodes conf >>= \case
            [] -> return ()
            errs -> liftIO $ do
                putStrLn $ "nodeUp failed on following nodes: " ++ show errs
                exitFailure
      where
        nodes = conjureRemoteNodeId <$> hosts
        conf = cfg { NodeAdd.configTrackers = Configured st }

    loadInitialData satellites _ fn roles | dry = do
        out $ "# load intitial data"
        out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " satellites
            ++ " mero load -f " ++ fn ++ " -r " ++ roles
    loadInitialData satellites datum _ _ = do
        verbose "Loading initial data"
        subscribeOnTo eqnids (Proxy :: Proxy InitialDataLoaded)
        promulgateEQ eqnids datum >>= \pid -> withMonitor pid wait
        expectTimeout step_delay >>= \v -> do
            unsubscribeOnFrom eqnids (Proxy :: Proxy InitialDataLoaded)
            case v of
                Nothing -> liftIO $ do
                    putStrLn "Timed out waiting for initial data to load."
                    exitFailure
                Just p -> case pubValue p of
                    InitialDataLoaded -> return ()
                    InitialDataLoadFailed e -> liftIO $ do
                        putStrLn $ "Initial data load failed: " ++ e
                        exitFailure
      where
        wait = void (expect :: Process ProcessMonitorNotification)
        eqnids = conjureRemoteNodeId <$> satellites

    startCluster stations | dry = do
        out $ "# Start cluster"
        out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " stations
            ++ " mero start"
    startCluster stations = do
        verbose "Requesting cluster start"
        promulgateEQ stnodes ClusterStartRequest >>= flip withMonitor wait
      where
        stnodes = conjureRemoteNodeId <$> stations
        wait = void (expect :: Process ProcessMonitorNotification)

-- | Parse options.
parseHelper :: Opt.Parser a -> String -> Either Opt.ParseError a
parseHelper schm text = fst $
    Opt.runP (Opt.runParserFully Opt.SkipOpts schm t) Opt.defaultPrefs
  where t = words text

showParseError :: Opt.ParseError -> String
showParseError (Opt.ErrorMsg x) = "error: " ++ x
showParseError (Opt.InfoMsg x) = "error: " ++ x
showParseError Opt.ShowHelpText = "Invalid usage"
showParseError Opt.UnknownError = "Unknown error"
showParseError (Opt.MissingError _ _) = "Missing error"
