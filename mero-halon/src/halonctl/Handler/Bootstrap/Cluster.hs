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

import qualified HA.Service              as Service
import qualified HA.Services.SSPL        as SSPL
import qualified HA.Services.SSPLHL      as SSPLHL
import qualified HA.Services.DecisionLog as DLog
import           HA.EventQueue.Producer
import qualified Handler.Service         as Service
import qualified Handler.Bootstrap.TrackingStation as Station
import qualified Handler.Bootstrap.Satellite as Satellite
import           HA.Resources.Castor.Initial as CI
import HA.RecoveryCoordinator.Events.Castor.Cluster
import           Lookup (conjureRemoteNodeId)

import qualified Options.Applicative as Opt
import qualified Options.Applicative.Types as Opt
import qualified Options.Applicative.Internal as Opt
import           Data.Defaultable (Defaultable(..), defaultable, fromDefault)
import           Options.Schema.Applicative (mkParser)

import Control.Distributed.Process
import Control.Lens
import Control.Monad (when, (>=>), void)
import Data.Bifunctor
import qualified Data.HashMap.Strict as HM
import Data.List (intercalate, partition)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Typeable
import Data.Validation
import qualified Data.Yaml as Y
import GHC.Generics (Generic)

import System.Exit

data Config = Config
  { configInitialData :: Defaultable FilePath
  , configRoles  :: Defaultable FilePath
  , configDryRun :: Bool
  } deriving (Eq, Show, Ord, Generic, Typeable)

schema :: Opt.Parser Config
schema = let
    initial = defaultable "/etc/halon/halon_facts.yaml" . Opt.strOption
            $ Opt.long "file"
            <> Opt.short 'f'
            <> Opt.help "Halon facts file"
            <> Opt.metavar "FILEPATH"
    roles = defaultable "/etc/halon/role_maps/prov.ede" . Opt.strOption
          $ Opt.long "roles"
         <> Opt.short 'r'
         <> Opt.help "Halon roles file"
         <> Opt.metavar "FILEPATH"
    dry  = Opt.switch
          $ Opt.long "dry-run"
         <> Opt.short 'n'
         <> Opt.help "Do not actually start cluster, just log actions"
  in Config <$> initial <*> roles <*> dry

data HalonConfig = HalonConfig
      { _halonTrackingStationConfig :: String -- ^ Command line for tracking station
      , _halonSatelliteConfig :: String -- ^ Command line for satellite
      , _halonSSPLLLConfig :: String    -- ^ Command line for sspl-ll
      , _halonSSPLHLConfig :: String    -- ^ Command line for sspl-hl
      , _halonDecisionLogConfig :: String  -- ^ Command line for Decision Log
      , _halonStartClients :: Bool      -- ^ Should we start clients
      , _halonStartDecisionLog :: Bool  -- ^ Should we start decision-log
      , _halonServiceStartTimeout :: Int -- ^ Timeout to start service
      , _halonStepDelay :: Int -- ^ Delay between each two steps
      }

defaultHalonConfig :: HalonConfig
defaultHalonConfig = HalonConfig ""
                                 ""
                                 "-u sspluser -p sspl4ever"
                                 "-u sspluser -p sspl4ever"
                                 "-f /var/log/halond.decision.log"
                                 True
                                 True
                                 10000000 -- 10s
                                 1000000  -- 1s

data ValidatedConfig = ValidatedConfig
      { vcTsConfig :: (String, Station.Config)  -- ^ Tracking station config and it's representation
      , vcSatConfig :: (String, Satellite.Config) -- ^ Satellite config and it's representation
      , vcSLLConfig :: (String, SSPL.SSPLConf)    -- ^ SSPL-LL config
      , vcHLLConfig :: (String, SSPLHL.SSPLHLConf) -- ^ SSPL-HL config
      , vcDLConfig  :: (String, DLog.DecisionLogConf) -- ^ Desision log config
      , vcInitialData :: CI.InitialData -- ^ Parsed and expanded initil data.
      , vcHosts :: ([(String,String)],[(String,String)],[(String, String)])
          -- List ip addresses of the tracking stations, servers, clients
          -- respectivly
      }

bootstrap :: Config -> Process ()
bootstrap Config{..} = do

  -- Check services config files
  let validateTrackingStationCfg = (text,) <$> parseHelper Station.schema text
        where text = _halonTrackingStationConfig defaultHalonConfig
      validateSatelliteCfg = (text,) <$> parseHelper Satellite.schema text
        where text = _halonSatelliteConfig defaultHalonConfig
      validateSSPLLLCfg = (text,) <$> parseServiceHelper text
        where text = _halonSSPLLLConfig defaultHalonConfig
      validateSSPLHLCfg = (text,) <$> parseServiceHelper text
        where text = _halonSSPLHLConfig defaultHalonConfig
      validateDLCfg = (text,) <$> parseServiceHelper text
        where text = _halonDecisionLogConfig defaultHalonConfig

  -- XXX: a bit of overlapping
  expanded <- liftIO $ CI.parseInitialData (fromDefault configInitialData)
                                           (fromDefault configRoles)

  -- Check halon facts and get interseting info
  ehosts <- liftIO $ do
    datum <- first (\e -> [ "Error when processing halon_facts file: "
                          ++ Y.prettyPrintParseException e])
                   <$> (Y.decodeFileEither (fromDefault configInitialData))
    return $ case datum of
      Left e -> _Failure # e
      Right d ->
        let hosts = second (HM.lookup "lnid" >=> lnidToIP)
                       <$> _rolesinit_id_m0_servers d
            unwrap (fqdn, Nothing) = _Failure # ["Host " ++ _uhost_m0h_fqdn fqdn ++ "is missing lnid address."]
            unwrap (fqdn, Just x)  = _Success # (fqdn, x)
            lnidToIP (Y.String s) = Just (T.unpack (T.takeWhile (/='@') s) ++ ":9000")
            lnidToIP _          = Nothing
        in traverse unwrap hosts <&> \u ->
             let  (clients, servers) = partition (\uh ->
                     let roles = _uhost_m0h_roles (fst uh)
                     in all (\(RoleSpec nm _) -> nm == "ha" || nm == "m0t1fs") roles)
                     u
                  stations = filter (\uh ->
                    let roles = _uhost_m0h_roles (fst uh)
                     in any (\(RoleSpec nm _) -> nm == "confd") roles)
                     servers
              in ( first _uhost_m0h_fqdn <$> stations
                 , first _uhost_m0h_fqdn <$> servers
                 , first _uhost_m0h_fqdn <$> clients
                 )
  einitData <- liftIO $ CI.parseInitialData (fromDefault configInitialData)
                                            (fromDefault configRoles)
  -- Create validated config
  let evalidatedConfig :: AccValidation [String] ValidatedConfig
      evalidatedConfig = ValidatedConfig
       <$> (first (\e -> ["Error when reading tracking station config:  " ++ show e])
              validateTrackingStationCfg ^. from _Either)
       <*> (first (\e -> ["Error when reading satellite config: " ++ show e])
              validateSatelliteCfg  ^. from _Either)
       <*> (first (\e -> ["Error when reading sspl-ll config: " ++ show e])
              validateSSPLLLCfg ^. from _Either)
       <*> (first (\e -> ["Error when reading sspl-hl config: " ++ show e])
              validateSSPLHLCfg ^. from _Either)
       <*> (first (\e -> ["Error when reading decision log config: " ++ show e])
              validateDLCfg ^. from _Either)
       <*> (first (\e -> ["Error when expanding initial data: " ++ show e])
              expanded ^. from _Either)
       <*>  ehosts
       <*  (first (\e -> ["Failure when parsing initial data: " ++ show e])
              einitData ^. from _Either)

  -- run bootstrap
  case evalidatedConfig of
    AccFailure strs -> liftIO $ do
      putStrLn "Failed to validate settings: "
      mapM_ putStrLn strs
    AccSuccess ValidatedConfig{..} -> do
      when dry $ do
        out "#!/bin/sh"
        out "set -xe"

      let ( snd . unzip -> station_hosts
           , snd . unzip -> satellite_hosts
           , snd . unzip -> client_hosts) = vcHosts

      bootstrapStation vcTsConfig station_hosts
      bootstrapSatellites vcSatConfig station_hosts satellite_hosts
      when (_halonStartClients defaultHalonConfig) $
        bootstrapSatellites vcSatConfig station_hosts client_hosts
      when (_halonStartDecisionLog defaultHalonConfig) $
        startDecisionLog vcDLConfig (head station_hosts)
      startSSPLLL vcSLLConfig station_hosts satellite_hosts
      startSSPLHL vcHLLConfig station_hosts satellite_hosts
      loadInitialData station_hosts
                      vcInitialData
                      (fromDefault configInitialData)
                      (fromDefault configRoles)
      startCluster station_hosts
      _ <- receiveTimeout step_delay []
      return ()
  where
    dry = configDryRun
    out = liftIO . putStrLn
    start_timeout = _halonServiceStartTimeout defaultHalonConfig
    step_delay    = _halonStepDelay defaultHalonConfig
    -- Bootstrap all halon stations.
    bootstrapStation :: (String, Station.Config) -> [String] -> Process ()
    bootstrapStation (str, _) hosts | dry = do
       out "# Starting stations"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " hosts ++ " bootstrap station" ++ str
    bootstrapStation (_, conf) hosts =
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
    -- Start decision log service
    startDecisionLog :: (String,DLog.DecisionLogConf) -> String -> Process ()
    startDecisionLog (cfg, _) ts | dry = do
       out "# Starting decision-log service"
       out $ "halonctl -l $IP:0 -a " ++ ts
                ++ " service decision-log start " ++ cfg
    startDecisionLog (_,cfg) station = do
        Service.start start_timeout (DLog.decisionLog) cfg [node] node
        _ <- receiveTimeout step_delay []
        return ()
      where
        node = conjureRemoteNodeId station
    -- Start SSPL HL service
    startSSPLLL :: (String,SSPL.SSPLConf) -> [String] -> [String] -> Process ()
    startSSPLLL (cfg, _) stations satellites | dry = do
       out $ "# Starting sspl-ll service"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " satellites
             ++ " service sspl start " ++ cfg ++ " -t "
             ++ intercalate " -t " stations
    startSSPLLL (_,cfg) stations satellites = do
        mapM_ (Service.start start_timeout (SSPL.sspl) cfg stnodes)
               nodes
        _ <- receiveTimeout step_delay []
        return ()
      where
        stnodes = conjureRemoteNodeId <$> stations
        nodes = conjureRemoteNodeId <$> satellites
    -- Start SSPL HL service
    startSSPLHL :: (String, SSPLHL.SSPLHLConf) -> [String] -> [String] -> Process ()
    startSSPLHL (cfg,_) stations satellites | dry = do
       out $ "# Starting sspl-hl service"
       out $ "halonctl -l $IP:0 -a " ++ intercalate " -a " satellites
             ++ " service sspl-hl start " ++ cfg ++ " -t "
             ++ intercalate " -t " stations
    startSSPLHL (_, cfg) stations satellites = do
        mapM_ (Service.start start_timeout (SSPLHL.sspl) cfg  stnodes)
               nodes
        _ <- receiveTimeout step_delay []
        return ()
      where
        stnodes = conjureRemoteNodeId <$> stations
        nodes = conjureRemoteNodeId <$> satellites

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
        (schan, rchan) <- newChan
        promulgateEQ stnodes (ClusterStartRequest schan) >>= flip withMonitor wait
        _ <- receiveChan rchan
        return ()
      where
        stnodes = conjureRemoteNodeId <$> stations
        wait = void (expect :: Process ProcessMonitorNotification)
--
-- | Parse options.
parseServiceHelper :: Service.Configuration a => String -> Either Opt.ParseError a
parseServiceHelper = parseHelper (mkParser $ Service.schema)

parseHelper :: Opt.Parser a -> String -> Either Opt.ParseError a
parseHelper schm text = fst $
    Opt.runP (Opt.runParserFully Opt.SkipOpts schm t) Opt.defaultPrefs
  where t = words text

