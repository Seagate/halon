{-# LANGUAGE CPP        #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Cluster-wide configuration.

module Handler.Cluster
  ( ClusterOptions
  , parseCluster
  , cluster
  ) where

import HA.EventQueue.Producer (promulgateEQ)
import qualified HA.Resources.Castor.Initial as CI

#ifdef USE_MERO
import qualified Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import HA.Resources.Mero (SyncToConfd(..), SyncDumpToBSReply(..))
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.Resources.Castor as Castor
import HA.RecoveryCoordinator.Events.Castor.Cluster

import Mero.ConfC (ServiceType(..), fidToStr, strToFid)
#endif

import Data.Foldable
import Options.Applicative
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad (void, unless)
import Control.Exception (evaluate)

import Data.Yaml
  ( prettyPrintParseException
  )
import qualified Options.Applicative as Opt
import qualified Options.Applicative.Extras as Opt

data ClusterOptions =
    LoadData LoadOptions
#ifdef USE_MERO
  | Sync SyncOptions
  | Dump DumpOptions
  | Status StatusOptions
  | Start StartOptions
  | Stop  StopOptions
  | ClientCmd ClientOptions
#endif
  deriving (Eq, Show)

parseCluster :: Opt.Parser ClusterOptions
parseCluster =
      ( LoadData <$> Opt.subparser ( Opt.command "load" (Opt.withDesc parseLoadOptions
        "Load initial data into the system." )))
#ifdef USE_MERO
  <|> ( Sync <$> Opt.subparser ( Opt.command "sync" (Opt.withDesc (pure SyncOptions)
        "Force synchronisation of RG to confd servers." )))
  <|> ( Dump <$> Opt.subparser ( Opt.command "dump" (Opt.withDesc parseDumpOptions
        "Dump embedded confd database to file." )))
  <|> ( Status <$> Opt.subparser ( Opt.command "status" (Opt.withDesc parseStatusOptions
        "Query mero-cluster status")))
  <|> ( Start <$> Opt.subparser ( Opt.command "start" (Opt.withDesc (pure StartOptions)
        "Start mero cluster")))
  <|> ( Stop <$> Opt.subparser ( Opt.command "stop" (Opt.withDesc (pure StopOptions)
        "Stop mero cluster")))
  <|> ( ClientCmd <$> Opt.subparser ( Opt.command "client" (Opt.withDesc parseClientOptions
        "Control m0t1fs clients")))
#endif

cluster :: [NodeId] -> ClusterOptions -> Process ()
cluster nids (LoadData l) = dataLoad nids l
#ifdef USE_MERO
cluster nids (Sync _) = syncToConfd nids
cluster nids (Dump s) = dumpConfd nids s
cluster nids (Status (StatusOptions m)) = clusterCommand nids ClusterStatusRequest (liftIO . output m)
  where output True = jsonReport
        output False = prettyReport
cluster nids (Start _)  = clusterCommand nids ClusterStartRequest (liftIO . print)
cluster nids (Stop  _)  = clusterCommand nids ClusterStopRequest (liftIO . print)
cluster nids (ClientCmd s) = client nids s
#endif

data LoadOptions = LoadOptions
    FilePath -- ^ Facts file
    FilePath -- ^ Roles file
    Bool -- ^ validate only
  deriving (Eq, Show)

parseLoadOptions :: Opt.Parser LoadOptions
parseLoadOptions = LoadOptions
  <$> Opt.strOption
      ( Opt.long "conffile"
     <> Opt.short 'f'
     <> Opt.help "File containing JSON-encoded configuration."
     <> Opt.metavar "FILEPATH"
      )
  <*> Opt.strOption
      ( Opt.long "rolesfile"
     <> Opt.short 'r'
     <> Opt.help "File containing template file with role mappings."
     <> Opt.metavar "FILEPATH"
     <> Opt.showDefaultWith id
     <> Opt.value "/etc/halon/mero_role_mappings"
      )
  <*> Opt.switch
      ( Opt.long "verify"
     <> Opt.short 'v'
     <> Opt.help "Verify config file without reconfiguring cluster."
      )

dataLoad :: [NodeId] -- ^ EQ nodes to send data to
         -> LoadOptions
         -> Process ()
dataLoad eqnids (LoadOptions cf maps verify) = do
  initData <- liftIO $ CI.parseInitialData cf maps
  case initData of
    Left err -> liftIO . putStrLn $ prettyPrintParseException err
    Right datum | verify -> liftIO $ do
      putStrLn "Initial data file parsed successfully."
      print datum
    Right (datum :: CI.InitialData) -> promulgateEQ eqnids datum
        >>= \pid -> withMonitor pid wait
      where
        wait = void (expect :: Process ProcessMonitorNotification)

#ifdef USE_MERO

syncToConfd :: [NodeId]
            -> Process ()
syncToConfd eqnids = promulgateEQ eqnids SyncToConfdServersInRG
        >>= \pid -> withMonitor pid wait
  where
    wait = void (expect :: Process ProcessMonitorNotification)

data SyncOptions = SyncOptions
  deriving (Eq, Show)

newtype DumpOptions = DumpOptions FilePath
  deriving (Eq, Show)

data StatusOptions = StatusOptions Bool deriving (Eq, Show)
data StartOptions  = StartOptions deriving (Eq, Show)
data StopOptions   = StopOptions deriving (Eq, Show)
data ClientOptions = ClientStopOption String
                   | ClientStartOption String
                   deriving (Eq, Show)

parseDumpOptions :: Opt.Parser DumpOptions
parseDumpOptions = DumpOptions <$>
  Opt.strOption
    ( Opt.long "filename"
    <> Opt.short 'f'
    <> Opt.help "File to dump confd database to."
    <> Opt.metavar "FILENAME"
    )

parseClientOptions :: Opt.Parser ClientOptions
parseClientOptions = Opt.subparser startCmd
                 <|> Opt.subparser stopCmd
  where
    startCmd = Opt.command "start" $
       Opt.withDesc (ClientStartOption <$> fidOption) "Start m0t1fs service"
    stopCmd = Opt.command "stop" $
       Opt.withDesc (ClientStopOption <$> fidOption) "Stop m0t1fs service"
    fidOption =  Opt.strOption
       ( Opt.long "fid"
       <> Opt.short 'f'
       <> Opt.help "Fid of the service"
       <> Opt.metavar "FID"
       )

parseStatusOptions :: Opt.Parser StatusOptions
parseStatusOptions = StatusOptions
  <$> Opt.switch
       ( Opt.long "json"
       <> Opt.help "Output in json format."
       )

dumpConfd :: [NodeId]
          -> DumpOptions
          -> Process ()
dumpConfd eqnids (DumpOptions fn) = do
  self <- getSelfPid
  promulgateEQ eqnids (SyncDumpToBS self) >>= flip withMonitor wait
  expect >>= \case
    SyncDumpToBSReply (Left err) ->
      say $ "Dumping conf to " ++ fn ++ " failed with " ++ err
    SyncDumpToBSReply (Right bs) -> do
      liftIO $ BS.writeFile fn bs
      say $ "Dumped conf in RG to this file " ++ fn
  where
    wait = void (expect :: Process ProcessMonitorNotification)

client :: [NodeId]
       -> ClientOptions
       -> Process ()
client eqnids (ClientStopOption fn) = do
  case strToFid fn of
    Just fid -> do
      promulgateEQ eqnids (StopMeroClientRequest fid) >>= flip withMonitor wait
      say "Command was delivered to EQ."
    Nothing -> say "Incorrect Fid format."
  where
    wait = void (expect :: Process ProcessMonitorNotification)
client eqnids (ClientStartOption fn) = do
  case strToFid fn of
    Just fid -> do
      promulgateEQ eqnids (StartMeroClientRequest fid) >>= flip withMonitor wait
      say "Command was delivered to EQ."
    Nothing -> say "Incorrect Fid format."
  where
    wait = void (expect :: Process ProcessMonitorNotification)

clusterCommand :: (Serializable a, Serializable b, Show b)
               => [NodeId]
               -> (SendPort b -> a)
               -> (b -> Process ())
               -> Process ()
clusterCommand eqnids mk output = do
  (schan, rchan) <- newChan
  promulgateEQ eqnids (mk schan) >>= flip withMonitor wait
  output =<< receiveChan rchan
  where
    wait = void (expect :: Process ProcessMonitorNotification)

prettyReport :: ReportClusterState -> IO ()
prettyReport (ReportClusterState status sns info' hosts) = do
  putStrLn $ "Cluster is " ++ maybe "N/A" M0.prettyStatus status
  case info' of
    Nothing -> putStrLn "cluster information is not available, load initial data.."
    Just (M0.Profile pfid, M0.Filesystem ffid _)  -> do
      putStrLn   "  cluster info:"
      putStrLn $ "    profile:    " ++ fidToStr pfid
      putStrLn $ "    filesystem: " ++ fidToStr ffid
      unless (null sns) $ do
         putStrLn $ "    sns repairs:"
         forM_ sns $ \(M0.Pool pool_fid, s) -> do
           putStrLn $ "      " ++ fidToStr pool_fid ++ ":"
           forM_ (M0.priStateUpdates s) $ \(M0.SDev{d_fid=sdev_fid,d_path=sdev_path},_) -> do
             putStrLn $ "        " ++ fidToStr sdev_fid ++ " -> " ++ sdev_path
      putStrLn $ "Hosts:"
      forM_ hosts $ \(Castor.Host qfdn, ReportClusterHost st ps sdevs) -> do
         putStrLn $ "  " ++ qfdn ++ " ["++ M0.prettyConfObjState st ++ "]"
         forM_ ps $ \(M0.Process{r_fid=rfid, r_endpoint=endpoint}, ReportClusterProcess proc_st srvs) -> do
           putStrLn $ "    " ++ "[" ++ M0.prettyProcessState proc_st ++ "]\t"
                             ++ endpoint ++ "\t" ++ inferType (map fst srvs) ++ "\t==> " ++ fidToStr rfid
           for_ srvs $ \(M0.Service fid' t' _ _, sst) -> do
             putStrLn $ "        [" ++ show sst ++ "]\t" ++ show t' ++ "\t\t\t==> " ++ fidToStr fid'
         unless (null sdevs) $ do
           putStrLn "    Devices:"
           forM_ sdevs $ \(M0.SDev{d_fid=sdev_fid,d_path=sdev_path}, sdev_st) -> do
             putStrLn $ "        " ++ fidToStr sdev_fid ++ "\tat " ++ sdev_path ++ "\t[" ++ M0.prettyConfObjState sdev_st ++ "]"
   where
     inferType srvs
       | any (\(M0.Service _ t _ _) -> t == CST_IOS) srvs = "ioservice"
       | any (\(M0.Service _ t _ _) -> t == CST_MDS) srvs = "mdservice"
       | any (\(M0.Service _ t _ _) -> t == CST_MGS) srvs = "confd    "
       | any (\(M0.Service _ t _ _) -> t == CST_HA)  srvs = "halon    "
       | otherwise                                        = "m0t1fs   "

jsonReport :: ReportClusterState -> IO ()
jsonReport = BSL.putStrLn . Data.Aeson.encode
#endif
