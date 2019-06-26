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

import           Control.Distributed.Process hiding (die)
import           Control.Lens
import           Control.Monad (unless, when, void)
import           Data.Bifunctor
import           Data.Defaultable (Defaultable(..), defaultable, fromDefault)
import           Data.Foldable (for_, traverse_)
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
import           Network.CEP (pubValue)
import qualified Options.Applicative as Opt
import qualified Options.Applicative.Common as Opt
import qualified Options.Applicative.Internal as Opt
import qualified Options.Applicative.Types as Opt
import           System.Environment (lookupEnv)
import           System.Exit (die)
import           System.IO (hPutStrLn, stderr)

data Options = Options
  { optFacts :: Defaultable FilePath
  , optRolesMero :: Defaultable FilePath
  , optRolesHalon :: Defaultable FilePath
  , optDryRun :: Bool
  , optVerbose :: Bool
  , optMkfsDone :: Bool
  } deriving (Eq, Show, Ord, Generic, Typeable)

parser :: Opt.Parser Options
parser = let
    -- XXX TODO: rename to "/etc/halon/facts.yaml"
    facts = defaultable "/etc/halon/halon_facts.yaml" . Opt.strOption
          $ Opt.long "facts"
         <> Opt.short 'f'
         <> Opt.help "Halon facts file"
         <> Opt.metavar "FILEPATH"
    -- XXX TODO: rename to "/etc/halon/roles-mero.yaml"
    rolesMero = defaultable "/etc/halon/mero_role_mappings" . Opt.strOption
          $ Opt.long "roles" -- XXX TODO: rename to "roles-mero"
         <> Opt.short 'r'
         <> Opt.help "Mero roles file used by Halon"
         <> Opt.metavar "FILEPATH"
    -- XXX TODO: rename to "/etc/halon/roles-halon.yaml"
    rolesHalon = defaultable "/etc/halon/halon_role_mappings" . Opt.strOption
          $ Opt.long "halonroles" -- XXX TODO: rename to "roles-halon"
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
         <> Opt.help "Do not run mkfs on a cluster"
  in Options <$> facts <*> rolesMero <*> rolesHalon <*> dry <*> verbose <*> mkfs

data Host = Host
  { hFqdn :: T.Text
  , hIp :: String
  , hRoles :: [CI.HalonRole]
  , hSvcs :: [( String          -- service start command
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

mkValidatedConfig :: [CI.Site]
                  -> ([CI.RoleSpec] -> Either String [CI.HalonRole])
                  -> String -- ^ Tracking station options.
                  -> Validation [String] ValidatedConfig
mkValidatedConfig sites mkRoles stationOpts =
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
    validateSatelliteOpts = let text = "" -- XXX Why bother parsing
                                          -- empty string?
                            in (text,) <$> parseHelper NodeAdd.parser text

    hosts :: [(CI.Host, CI.HalonSettings)]
    hosts = [ (host, h0params) | site <- sites
                               , rack <- CI.site_racks site
                               , encl <- CI.rack_enclosures rack
                               , host <- CI.enc_hosts encl
                               , Just h0params <- [CI.h_halon host] ]

    ehosts :: Validation [String] [Host]
    ehosts = filter (not . null . hRoles) <$> traverse expandHost hosts

    expandHost :: (CI.Host, CI.HalonSettings) -> Validation [String] Host
    expandHost (host, h0params) = case mkRoles (CI._hs_roles h0params) of
        Left err -> _Failure # ["Halon role failure for "
                                ++ T.unpack (CI.h_fqdn host) ++ ": " ++ err]
        Right roles -> (\svcs -> Host { hFqdn = CI.h_fqdn host
                                      , hIp = CI._hs_address h0params
                                      , hRoles = roles
                                      , hSvcs = svcs
                                      }
                        ) <$> parseSvcs roles

    parseSvcs :: [CI.HalonRole]
              -> Validation [String] [(String, Service.Options)]
    parseSvcs = sequenceA . map parseSvc . concatMap CI._hc_h_services

    parseSvc :: String -> Validation [String] (String, Service.Options)
    parseSvc str = case parseHelper Service.parser str of
        Left err -> _Failure # ["Failure to parse service \"" ++ str ++ "\": "
                              ++ showParseError err]
        Right conf -> _Success # (str, conf)

run :: Options -> Process ()
run opts@Options{..} = do
    einitData <- liftIO $ CI.parseInitialData (fromDefault optFacts)
                                              (fromDefault optRolesHalon)
    case einitData of
        Left err -> perrors ("Failed to load initial data:":[show err])
        Right (initialData, halonRolesObj) -> do
            stationOpts <- liftIO $
                fromMaybe "" <$> lookupEnv "HALOND_STATION_OPTIONS"
            let evConfig = mkValidatedConfig (CI.id_sites initialData)
                                             (CI.mkHalonRoles halonRolesObj)
                                             stationOpts
            case evConfig of
                Failure errs -> perrors ("Failed to validate settings:":errs)
                Success vconf -> bootstrap initialData vconf opts
  where
    perrors :: [String] -> Process ()
    perrors = traverse_ out2

bootstrap :: CI.InitialData -> ValidatedConfig -> Options -> Process ()
bootstrap initialData ValidatedConfig{..} Options{..} = do
    verboseDumpFile "Halon facts" optFacts
    verboseDumpFile "Mero roles" optRolesMero
    verboseDumpFile "Halon roles" optRolesHalon

    when dry $ do
        out "#!/usr/bin/env bash"
        out "set -eu -o pipefail"
        out "set -x"
        out ""

    let getIps :: ([CI.HalonRole] -> Bool) -> [String]
        getIps p = map hIp $ filter (p . hRoles) vcHosts

        stationHosts = getIps $ any CI._hc_h_bootstrap_station -- TS
        satelliteHosts = getIps $ const True -- no TS, some services

    if null stationHosts
      then out2 "No station hosts, can't do anything"
      else do
        bootstrapStation vcTsConfig stationHosts
        bootstrapSatellites vcSatConfig stationHosts satelliteHosts

        out "# Starting services"
        for_ vcHosts $ \Host{..} -> do
            unless (null hSvcs) . out $ "# Services for " ++ show hFqdn
            for_ hSvcs $ \svc -> startService hIp svc stationHosts

        loadInitialData stationHosts
                        initialData
                        (fromDefault optFacts)
                        (fromDefault optRolesMero)

        when optMkfsDone $ do
            if dry
            then out $ "halonctl -l $IP:0 mero mkfs-done --confirm"
                    ++ preintercalate " -t " stationHosts
            else do
                let stnodes = nids stationHosts
                (sp, rp) <- newChan
                promulgateEQ_ stnodes (MarkProcessesBootstrapped sp)
                void $ receiveWait [matchChan rp (const $ return ())]

        startCluster stationHosts
        unless dry $ void $ receiveTimeout stepDelay []
  where
    dry = optDryRun
    out = liftIO . putStrLn
    verbose = if optVerbose then liftIO . putStrLn else const (return ())
    stepDelay = 10000000

    verboseDumpFile :: String -> Defaultable FilePath -> Process ()
    verboseDumpFile title path = when optVerbose . liftIO $ do
        putStrLn $ "--- " ++ title ++ " ---"
        readFile (fromDefault path) >>= putStrLn
        putStrLn "----------"

    nids :: [String] -> [NodeId]
    nids = map conjureRemoteNodeId

    preintercalate :: [a] -> [[a]] -> [a]
    preintercalate xs xss = xs ++ intercalate xs xss

    hctl :: [String] -> String
    hctl [] = error "Invalid argument"
    hctl targets = "halonctl -l $IP:0" ++ preintercalate " -a " targets

    bootstrapStation :: (String, Station.Options) -> [String] -> Process ()
    bootstrapStation (str, _) stations | dry = do
        out "# Starting stations"
        out $ hctl stations ++ " halon station " ++ str
    bootstrapStation (_, conf) stations = do
        verbose $ "Starting stations: " ++ show stations
        Station.start (nids stations) conf

    bootstrapSatellites :: (String, NodeAdd.Options)
                        -> [String]
                        -> [String]
                        -> Process ()
    bootstrapSatellites _ stations satellites | dry = do
        out "# Starting satellites"
        out $ hctl satellites
            ++ " halon node add" ++ preintercalate " -t " stations
    bootstrapSatellites (_, conf) stations satellites = do
        verbose $ "Starting satellites: " ++ show satellites
        let conf' = conf { NodeAdd.configTrackers = Configured stations }
        NodeAdd.run (nids satellites) conf' >>= \case
            [] -> return ()
            errs -> liftIO . die $
                "nodeUp failed on following nodes: " ++ show errs

    startService :: String
                 -> (String, Service.Options)
                 -> [String]
                 -> Process ()
    startService ip (str, _) stations | dry =
        out $ hctl [ip]
            ++ " halon service " ++ str ++ preintercalate " -t " stations
    startService ip (_, conf) _ =
        Service.service [conjureRemoteNodeId ip] conf

    loadInitialData stations _ fn roles | dry = do
        out $ "# Loading intitial data"
        out $ hctl stations ++ " mero load -f " ++ fn ++ " -r " ++ roles
    loadInitialData stations datum _ _ = do
        verbose "Loading initial data"
        let eqnids = nids stations
        subscribeOnTo eqnids (Proxy :: Proxy InitialDataLoaded)
        promulgateEQ eqnids datum >>= withMonitorWait
        expectTimeout stepDelay >>= \v -> do
            unsubscribeOnFrom eqnids (Proxy :: Proxy InitialDataLoaded)
            case v of
                Nothing ->
                    liftIO $ die "Timed out waiting for initial data to load"
                Just p -> case pubValue p of
                    InitialDataLoadFailed err -> liftIO . die $
                        "Initial data load failed: " ++ err
                    InitialDataLoaded -> return ()

    startCluster :: [String] -> Process ()
    startCluster stations | dry = do
        out $ "# Starting cluster"
        out $ hctl stations ++ " mero start"
    startCluster stations = do
        verbose "Requesting cluster start"
        promulgateEQ (nids stations) ClusterStartRequest >>= withMonitorWait

-- | Parse options.
parseHelper :: Opt.Parser a -> String -> Either Opt.ParseError a
parseHelper schm text = fst $
    Opt.runP (Opt.runParserFully Opt.Intersperse schm t) Opt.defaultPrefs
  where t = words text

showParseError :: Opt.ParseError -> String
showParseError (Opt.ErrorMsg x) = "error: " ++ x
showParseError (Opt.InfoMsg x) = "error: " ++ x
showParseError Opt.ShowHelpText = "Invalid usage"
showParseError Opt.UnknownError = "Unknown error"
showParseError (Opt.MissingError _ _) = "Missing error"
showParseError (Opt.ExpectsArgError x) = "Expected arg error: " ++ x
showParseError (Opt.UnexpectedError x _) = "Unexpected error: " ++ x

out2 :: String -> Process ()
out2 = liftIO . hPutStrLn stderr

withMonitorWait :: ProcessId -> Process ()
withMonitorWait =
    let wait = void (expect :: Process ProcessMonitorNotification)
    in flip withMonitor wait
