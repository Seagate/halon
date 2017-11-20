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
  , run
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
import           HA.Resources.Castor.Initial as CI
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
    meroRoles = defaultable "/etc/halon/role_maps/prov.ede" . Opt.strOption
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

data ValidatedConfig = ValidatedConfig
      { vcTsConfig :: (String, Station.Options)  -- ^ Tracking station config and it's representation
      , vcSatConfig :: (String, NodeAdd.Options) -- ^ Satellite config and it's representation
      , vcHosts :: [(T.Text, String, [HalonRole], [(String, Service.Options)])]
        -- ^ Addresses of hosts and their halon roles: @(fqdn, ip, roles, (servicestrings, parsedserviceconfs))@
      }

run :: Options -> Process ()
run Options{..} = do
  einitData <- liftIO $ CI.parseInitialData (fromDefault configInitialData)
                                            (fromDefault configMeroRoles)
                                            (fromDefault configHalonRoles)
  case einitData of
    Left err -> liftIO . putStrLn $ "Failed to load initial data: " ++ show err
    Right (initialData, halonRoleObj) -> do
      -- Check services config files
      station_opts <- fmap (fromMaybe "") . liftIO $ lookupEnv "HALOND_STATION_OPTIONS"
      let validateTrackingStationCfg = (text,) <$> parseHelper Station.parser text
            where text = station_opts
          validateSatelliteCfg = (text,) <$> parseHelper NodeAdd.parser text
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
            Left err -> _Failure # ["Halon role failure for " ++ T.unpack (h_fqdn h) ++ ": " ++ err]
            Right hRoles -> (\srvs -> (h_fqdn h, _hs_address hs, hRoles, srvs))
                            <$> parseSrvs hRoles

          parseSrvs = sequenceA . map parseSrv . concatMap _hc_h_services

          parseSrv str = case parseHelper Service.parser str of
            Left e -> _Failure # ["Failure to parse service \"" ++ str ++ "\": " ++ printParseError e]
            Right conf -> _Success # (str, conf)

      -- Create validated config
      let evalidatedConfig :: AccValidation [String] ValidatedConfig
          evalidatedConfig = ValidatedConfig
           <$> (first (\e -> ["Error when reading tracking station config:  " ++ printParseError e])
                  validateTrackingStationCfg ^. from _Either)
           <*> (first (\e -> ["Error when reading satellite config: " ++ printParseError e])
                  validateSatelliteCfg  ^. from _Either)
           <*>  ehosts

      -- run bootstrap
      case evalidatedConfig of
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
              unless configDryRun $
                receiveTimeout step_delay [] >> return ()
  where
    dry = configDryRun
    out = liftIO . putStrLn
    verbose = liftIO . if configVerbose then putStrLn else const (return ())
    step_delay    = 10000000

    startService :: String -> (String, Service.Options) -> [String] -> Process ()
    startService host (srvString, conf) stations
      | dry = do
          out $ "halonctl -l $IP:0 -a " ++ host
             ++ " halon service " ++ srv
      | otherwise = Service.service [conjureRemoteNodeId host] conf
      where
        srv = srvString ++ " -t " ++ intercalate " -t " stations

    -- Bootstrap all halon stations.
    bootstrapStation :: (String, Station.Options) -> [String] -> Process ()
    bootstrapStation (str, _) hosts | dry = do
       out "# Starting stations"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " hosts ++ " halon station" ++ str
    bootstrapStation (_, conf) hosts = do
      verbose $ "Starting stations: " ++ show hosts
      Station.start nodes conf
      where
        nodes = conjureRemoteNodeId <$> hosts
    -- Bootstrap satellites
    bootstrapSatellites :: (String, NodeAdd.Options) -> [String] -> [String] -> Process ()
    bootstrapSatellites _ stations hosts | dry = do
       out "# Starting satellites"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " hosts
                                     ++ " halon node add -t "
                                     ++ intercalate " -t " stations
    bootstrapSatellites (_, cfg) st hosts = do
      verbose $ "Starting satellites" ++ show hosts
      NodeAdd.run nodes conf >>= \case
        [] -> return ()
        failures -> liftIO $ do
          putStrLn $ "nodeUp failed on following nodes: " ++ show failures
          exitFailure
       where
         nodes = conjureRemoteNodeId <$> hosts
         conf = cfg{NodeAdd.configTrackers=Configured st}

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


-- | Print a parser error.
printParseError :: Opt.ParseError -> String
printParseError (Opt.ErrorMsg x) = "error: " ++ x
printParseError (Opt.InfoMsg x) = "error: " ++ x
printParseError Opt.ShowHelpText = "Invalid usage"
printParseError Opt.UnknownError = "Unknown error"
printParseError (Opt.MissingError _ _) = "Missing error"
