{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}
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

import HA.EventQueue (promulgateEQ)
import Control.Distributed.Process.Serializable
import Control.Monad.Fix (fix)
import Control.Monad.Catch (bracket_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Foldable
import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import Data.Proxy
import qualified Mero.Notification as M0
import qualified Mero.Notification.HAState as M0
import HA.EventQueue (eventQueueLabel, DoClearEQ(..), DoneClearEQ(..) )
import HA.Resources.Mero (SyncToConfd(..), SyncDumpToBSReply(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (showFid)
import qualified HA.Resources.Castor as Castor
import qualified HA.Resources.HalonVars as Castor
import qualified HA.Aeson
import HA.SafeCopy
import HA.RecoveryCoordinator.Castor.Cluster.Events
import HA.RecoveryCoordinator.Castor.Commands.Events
import HA.RecoveryCoordinator.Castor.Node.Events
import Mero.ConfC ( Fid )

import HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import HA.RecoveryCoordinator.RC.Events
import HA.RecoveryCoordinator.RC.Events.Cluster
import HA.RecoveryCoordinator.Mero.Events
import HA.RecoveryCoordinator.Mero (labelRecoveryCoordinator)
import Mero.ConfC (fidToStr, strToFid)
import Mero.Spiel (FSStats(..))
import Network.CEP
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import Text.Read (readMaybe)

import Control.Distributed.Process hiding (bracket_)
import Control.Monad
import Data.Yaml (prettyPrintParseException)
import qualified HA.Resources.Castor.Initial as CI
import Lookup (findEQFromNodes)
import Options.Applicative
import qualified Options.Applicative as Opt
import qualified Options.Applicative.Extras as Opt

data ClusterOptions =
    LoadData LoadOptions
  | Sync SyncOptions
  | Dump DumpOptions
  | Status StatusOptions
  | Start StartOptions
  | Stop  StopOptions
  | ClientCmd ClientOptions
  | NotifyCmd NotifyOptions
  | ResetCmd ResetOptions
  | MkfsDone MkfsDoneOptions
  | VarsCmd VarsOptions
  | StateUpdate StateUpdateOptions
  | StopNode StopNodeOptions
  | CastorDriveCommand DriveCommand
  deriving (Eq, Show)


parseCluster :: Opt.Parser ClusterOptions
parseCluster =
      ( LoadData <$> Opt.subparser ( Opt.command "load" (Opt.withDesc parseLoadOptions
        "Load initial data into the system." )))
  <|> ( Sync <$> Opt.subparser ( Opt.command "sync" (Opt.withDesc parseSyncOptions
        "Force synchronisation of RG to confd servers." )))
  <|> ( Dump <$> Opt.subparser ( Opt.command "dump" (Opt.withDesc parseDumpOptions
        "Dump embedded confd database to file." )))
  <|> ( Status <$> Opt.subparser ( Opt.command "status" (Opt.withDesc parseStatusOptions
        "Query mero-cluster status")))
  <|> ( Start <$> Opt.subparser ( Opt.command "start" (Opt.withDesc parseStartOptions
        "Start mero cluster")))
  <|> ( Stop <$> Opt.subparser ( Opt.command "stop" (Opt.withDesc parseStopOptions
        "Stop mero cluster")))
  <|> ( ClientCmd <$> Opt.subparser ( Opt.command "client" (Opt.withDesc parseClientOptions
        "Control m0t1fs clients")))
  <|> ( NotifyCmd <$> Opt.subparser ( Opt.command "notify" (Opt.withDesc parseNotifyOptions
        "Notify mero cluster" )))
  <|> ( ResetCmd <$> Opt.subparser ( Opt.command "reset" (Opt.withDesc parseResetOptions
        "Reset Halon's cluster knowledge to ground state." )))
  <|> ( MkfsDone <$> Opt.subparser ( Opt.command "mkfs-done" (Opt.withDesc parseMkfsDoneOptions
        "Mark all processes as finished mkfs.")))
  <|> ( VarsCmd  <$> Opt.subparser ( Opt.command "vars" (Opt.withDesc parseVarsOptions
        "Control variable parameters of the halon.")))
  <|> ( StateUpdate <$> Opt.subparser (Opt.command "update" (Opt.withDesc parseStateUpdateOptions
        "Force update state of the mero objects")))
  <|> ( StopNode <$> Opt.subparser (Opt.command "node-stop" (Opt.withDesc parseStopNodeOptions
         "Stop m0d processes on the given node")))
  <|> ( Opt.subparser $ command "drive" $ Opt.withDesc parseDriveCommand "Commands to drive")


data DriveCommand
  = DrivePresence String Castor.Slot Bool Bool
  | DriveStatus   String Castor.Slot String
  | DriveNew      String String
  deriving (Eq, Show)

parseDriveCommand :: Parser ClusterOptions
parseDriveCommand = CastorDriveCommand <$> asum
     [ Opt.subparser (command "update-presence"
        $ Opt.withDesc parseDrivePresence "Update information about drive presence")
     , Opt.subparser (command "update-status"
        $ Opt.withDesc parseDriveStatus "Update drive status")
     , Opt.subparser (command "new-drive"
        $ Opt.withDesc parseDriveNew "create new drive")
     ]
   where
     parseDriveNew :: Parser DriveCommand
     parseDriveNew = DriveNew <$> optSerial <*> optPath

     parseDrivePresence :: Parser DriveCommand
     parseDrivePresence = DrivePresence
        <$> optSerial
        <*> parseSlot
        <*> Opt.switch (long "is-installed" <>
                        help "Mark drive as installed")
        <*> Opt.switch (long "is-powered" <>
                        help "Mark drive as powered")
     parseDriveStatus :: Parser DriveCommand
     parseDriveStatus = DriveStatus
        <$> optSerial
        <*> parseSlot
        <*> strOption (long "status"
                      <> metavar "[EMPTY|OK]"
                      <> help "Set drive status")

optPath :: Parser String
optPath = strOption $ mconcat
  [ long "path"
  , short 'p'
  , help "Drive path"
  , metavar "PATH"
  ]


parseSlot :: Parser Castor.Slot
parseSlot = Castor.Slot
   <$> (Castor.Enclosure <$>
         strOption (mconcat [ long "slot-enclosure"
                            , help "index of the drive's enclosure"
                            , metavar "NAME"
                            ]))
   <*> option auto (mconcat [ long "slot-index"
                            , help "index of the drive's slot"
                            , metavar "INT"
                            ])

optSerial :: Parser String
optSerial = strOption $ mconcat
   [ long "serial"
   , short 's'
   , help "Drive serial number"
   , metavar "SERIAL"
   ]


-- | Run the specified cluster command over the given nodes. The nodes
-- are first verified to be EQ nodes: if they aren't, we use EQ node
-- list retrieved from the tracker instead.
cluster :: [NodeId] -> ClusterOptions -> Process ()
cluster nids' opt = do
  -- HALON-267: if user specified a cluster command but none of the
  -- addresses we list are a known EQ, try finding EQ on our own and
  -- using that instead
  rnids <- findEQFromNodes 5000000 nids' >>= \case
    [] -> do
      liftIO . putStrLn $ "Cluster command requested but no known EQ; trying specified nids anyway."
      return nids'
    ns -> return ns
  cluster' rnids opt

  where
    cluster' nids (LoadData l) = dataLoad nids l
    cluster' nids (Sync (SyncOptions f)) = do
      say "Synchonizing cluster to confd."
      syncToConfd nids f
    cluster' nids (Dump s) = dumpConfd nids s
    cluster' nids (Status (StatusOptions m d t)) = clusterCommand nids (Just t) ClusterStatusRequest (liftIO . output m d)
      where output True _ = jsonReport
            output False e = prettyReport e
    cluster' nids (Start (StartOptions async))  = do
      say "Starting cluster."
      clusterStartCommand nids async
    cluster' nids (Stop opts)  = clusterStopCommand nids opts
    cluster' nids (ClientCmd s) = client nids s
    cluster' nids (NotifyCmd (NotifyOptions s)) = notifyHalon nids s
    cluster' nids (ResetCmd r) = clusterReset nids r
    cluster' _    (MkfsDone (MkfsDoneOptions False)) = do
      liftIO $ putStrLn "Please check that cluster fits all requirements first."
    cluster' nids (MkfsDone (MkfsDoneOptions True)) = do
      clusterCommand nids Nothing MarkProcessesBootstrapped (const $ liftIO $ putStrLn "Done")
    cluster' nids (VarsCmd VarsGet) = clusterCommand nids Nothing GetHalonVars (liftIO . print)
    cluster' nids (VarsCmd s@VarsSet{}) = clusterHVarsUpdate nids s
    cluster' nids (StateUpdate (StateUpdateOptions s))
      = clusterCommand nids Nothing (ForceObjectStateUpdateRequest s) (liftIO . print)
    cluster' nids (StopNode options)
      = clusterStopNode nids options
    cluster' nids (CastorDriveCommand s) = runDriveCommand nids s

data LoadOptions = LoadOptions
    FilePath -- ^ Facts file
    FilePath -- ^ Roles file
    FilePath -- ^ Halon roles file
    Bool -- ^ validate only
    Int -- ^ Timeout (seconds)
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
  <*> Opt.strOption
      ( Opt.long "halonrolesfile"
     <> Opt.short 's'
     <> Opt.help "File containing template file with halon role mappings."
     <> Opt.metavar "FILEPATH"
     <> Opt.showDefaultWith id
     <> Opt.value "/etc/halon/halon_role_mappings"
      )
  <*> Opt.switch
      ( Opt.long "verify"
     <> Opt.short 'v'
     <> Opt.help "Verify config file without reconfiguring cluster."
      )
  <*> Opt.option Opt.auto
    ( Opt.metavar "TIMEOUT(s)"
    <> Opt.long "timeout"
    <> Opt.help "How many seconds to wait for initial data to load before failing."
    <> Opt.value 10
    <> Opt.showDefault )

dataLoad :: [NodeId] -- ^ EQ nodes to send data to
         -> LoadOptions
         -> Process ()
dataLoad eqnids (LoadOptions cf maps halonMaps verify _t) = do
  initData <- liftIO $ CI.parseInitialData cf maps halonMaps
  case initData of
    Left err -> liftIO $ do
      putStrLn $ prettyPrintParseException err
      exitFailure
    Right (datum, _) | verify -> liftIO $ do
      putStrLn "Initial data file parsed successfully."
      print datum
    Right ((datum :: CI.InitialData), _) -> do
      subscribeOnTo eqnids (Proxy :: Proxy InitialDataLoaded)
      promulgateEQ eqnids datum >>= flip withMonitor wait
      expectTimeout (_t * 1000000) >>= \v -> do
        unsubscribeOnFrom eqnids (Proxy :: Proxy InitialDataLoaded)
        case v of
          Nothing -> liftIO $ do
            hPutStrLn stderr "Timed out waiting for initial data to load."
            exitFailure
          Just p -> case pubValue p of
            InitialDataLoaded -> return ()
            InitialDataLoadFailed e -> liftIO $ do
              hPutStrLn stderr $ "Initial data load failed: " ++ e
              exitFailure
      where
        wait = void (expect :: Process ProcessMonitorNotification)

syncToConfd :: [NodeId]
            -> Bool     -- ^ Force synchoronization.
            -> Process ()
syncToConfd eqnids f = promulgateEQ eqnids (SyncToConfdServersInRG f)
        >>= \pid -> withMonitor pid wait
  where
    wait = void (expect :: Process ProcessMonitorNotification)

data SyncOptions = SyncOptions
  { _syncOptForce :: Bool }
  deriving (Eq, Show)

newtype DumpOptions = DumpOptions FilePath
  deriving (Eq, Show)

data StatusOptions = StatusOptions
  { _statusOptJSON :: Bool
  , _statusOptDevices :: Bool
  , _statusTimeout :: Int
  } deriving (Eq, Show)
data StartOptions  = StartOptions Bool deriving (Eq, Show)
data StopOptions   = StopOptions
  { _so_silent :: Bool
  , _so_async :: Bool
  , _so_timeout :: Int
  , _so_reason :: String }
  deriving (Eq, Show)

data ClientOptions = ClientStopOption String String
                   -- ^ @ClientStopOption fid reason@
                   | ClientStartOption String
                   deriving (Eq, Show)

newtype NotifyOptions = NotifyOptions [M0.Note]
  deriving (Eq, Show)
data ResetOptions = ResetOptions Bool Bool
  deriving (Eq, Show)
data MkfsDoneOptions  = MkfsDoneOptions Bool deriving (Eq, Show)

data VarsOptions
       = VarsGet
       | VarsSet
          { recoveryExpirySeconds :: Maybe Int
          , recoveryMaxRetries    :: Maybe Int
          , keepaliveFrequency    :: Maybe Int
          , keepaliveTimeout      :: Maybe Int
          , driveResetMaxRetries  :: Maybe Int
          , disableSmartCheck     :: Maybe Bool
          }
       deriving (Show, Eq)

parseNotifyOptions :: Opt.Parser NotifyOptions
parseNotifyOptions = NotifyOptions <$>
  Opt.many (Opt.option noteReader
    ( Opt.help "List of notes to send to halon. Format: <fid>@<conf object state>"
    <> Opt.long "note"
    <> Opt.metavar "NOTE"
    ))

noteReader :: Opt.ReadM M0.Note
noteReader = Opt.eitherReader readNote
  where
    readNote :: String -> Either String M0.Note
    readNote (break (== '@') -> (fid', '@':state)) = case (,) <$> strToFid fid' <*> readMaybe state of
      Nothing -> Left $ "Couldn't parse fid or state: " ++ show (fid', state)
      Just (fid'', state') -> Right $ M0.Note fid'' state'
    readNote s = Left $ "Could not parse: " ++ s

notifyHalon :: [NodeId] -> [M0.Note] -> Process ()
notifyHalon eqnids notes = do
  say $ "Sending " ++ show notes ++ " to halon."
  promulgateEQ eqnids (M0.Set notes Nothing) >>= flip withMonitor wait
  where
    wait = void (expect :: Process ProcessMonitorNotification)

newtype StateUpdateOptions = StateUpdateOptions [(Fid, String)]
  deriving (Eq, Show)

parseStateUpdateOptions :: Opt.Parser StateUpdateOptions
parseStateUpdateOptions = StateUpdateOptions <$>
  Opt.many (Opt.option (Opt.eitherReader updateReader)
    (  Opt.help "List of updates to send to halon. Format: <fid>@<conf state>"
    <> Opt.long "set"
    <> Opt.metavar "NOTE"
    ))
  where
   updateReader :: String -> Either String (Fid, String)
   updateReader (break (=='@') -> (fid', '@':state)) = case strToFid fid' of
     Nothing -> Left $ "Couldn't parse fid: " ++ show fid'
     Just fid -> Right $ (fid, state)
   updateReader s = Left $ "Could not parse " ++ s

data StopNodeOptions = StopNodeOptions
       { stopNodeForce :: Bool
       , stopNodeFid   :: String
       , stopNodeSync  :: Bool
       , stopNodeReason :: String
       } deriving (Eq, Show)

parseStopNodeOptions :: Opt.Parser StopNodeOptions
parseStopNodeOptions = StopNodeOptions
   <$> Opt.switch (Opt.long "force" <> Opt.short 'f' <> Opt.help "force stop, even if it reduces liveness.")
   <*> Opt.strOption (Opt.long "node" <> Opt.help "Node to shutdown" <>  Opt.metavar "NODE")
   <*> Opt.switch (Opt.long "sync" <> Opt.short 's' <> Opt.help "exit when operation finished.")
   <*> Opt.strOption (Opt.long "reason" <> Opt.help "Reason for stopping the node" <> Opt.value "unspecified" <> Opt.metavar "REASON")

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
       Opt.withDesc (ClientStopOption <$> fidOption <*> reasonOption) "Stop m0t1fs service"
    fidOption =  Opt.strOption
       ( Opt.long "fid"
       <> Opt.short 'f'
       <> Opt.help "Fid of the service"
       <> Opt.metavar "FID"
       )
    reasonOption = Opt.strOption
      ( Opt.long "reason"
      <> Opt.help "Reason for stopping the client"
      <> Opt.metavar "REASON"
      <> Opt.value "unspecified" )


parseStatusOptions :: Opt.Parser StatusOptions
parseStatusOptions = StatusOptions
  <$> Opt.switch
       ( Opt.long "json"
       <> Opt.help "Output in json format."
       )
  <*> Opt.switch
        ( Opt.long "show-devices"
       <> Opt.short 'd'
       <> Opt.help "Also show failed devices and their status. Devices are always shown in the JSON format.")
  <*> Opt.option Opt.auto
        ( Opt.metavar "TIMEOUT(s)"
       <> Opt.long "timeout"
       <> Opt.help "How long to wait for status, in seconds"
       <> Opt.value 10
       <> Opt.showDefault )

parseResetOptions :: Opt.Parser ResetOptions
parseResetOptions = ResetOptions
  <$> Opt.switch
    ( Opt.long "hard"
    <> Opt.help "Perform a hard reset. This clears the EQ and forces an RC restart."
    )
  <*> Opt.switch
    ( Opt.long "unstick"
    <> Opt.help "Clear the EQ and reset the RC remotely, in case of a stuck RC."
    )

parseSyncOptions :: Opt.Parser SyncOptions
parseSyncOptions = SyncOptions
  <$> Opt.switch
    ( Opt.long "force"
    <> Opt.help "Force transaction sync even if configuration tree didn't change")


parseStartOptions :: Opt.Parser StartOptions
parseStartOptions = StartOptions
  <$> Opt.switch
       ( Opt.long "async"
       <> Opt.short 'a'
       <> Opt.help "Do not wait for cluster start.")

parseStopOptions :: Opt.Parser StopOptions
parseStopOptions = StopOptions
  <$> Opt.switch
    ( Opt.long "silent"
    <> Opt.help "Do not print any output" )
  <*> Opt.switch
    ( Opt.long "async"
    <> Opt.help "Don't wait for stop to happen." )
  <*> Opt.option Opt.auto
    ( Opt.metavar "TIMEOUT(µs)"
    <> Opt.long "timeout"
    <> Opt.help "How long to wait for successful cluster stop before halonctl gives up on waiting."
    <> Opt.value 600000000
    <> Opt.showDefault )
  <*> Opt.strOption
    ( Opt.long "reason"
    <> Opt.help "Reason for stopping the cluster"
    <> Opt.metavar "REASON"
    <> Opt.value "unspecified" )

parseMkfsDoneOptions :: Opt.Parser MkfsDoneOptions
parseMkfsDoneOptions = MkfsDoneOptions
  <$> Opt.switch
    ( Opt.long "confirm"
    <> Opt.help "Confirm that all that cluster fits all requirements for running this call."
    )

parseVarsOptions :: Opt.Parser VarsOptions
parseVarsOptions
    =  Opt.subparser (Opt.command "get" (Opt.withDesc (pure VarsGet) "Load variables"))
   <|> Opt.subparser (Opt.command "set" (Opt.withDesc (inner) "Set variables"))
   where
     inner :: Opt.Parser VarsOptions
     inner = VarsSet <$> recoveryExpiry
                     <*> recoveryRetry
                     <*> keepaliveFreq
                     <*> keepaliveTimeout
                     <*> driveResetMax
                     <*> disableSmartCheck
     recoveryExpiry = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "recovery-expiry"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "How long we want node recovery to last overall (sec).")
     recoveryRetry = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "recovery-retry"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "Number of tries to try recovery, negative for infinite.")
     keepaliveFreq = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "keepalive-frequency"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "How ofter should we try to send keepalive messages. Seconds.")
     keepaliveTimeout = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "keepalive-timeout"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "How long to allow process to run without replying to keepalive.")
     driveResetMax = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "drive-reset-max-retries"
       <> Opt.metavar "[NUMBER]"
       <> Opt.help "Number of times we could try to reset drive.")
     disableSmartCheck = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "disable-smart-check"
       <>  Opt.metavar "[TRUE|FALSE]"
       <>  Opt.help "Disable smart check by sspl.")

dumpConfd :: [NodeId]
          -> DumpOptions
          -> Process ()
dumpConfd eqnids (DumpOptions fn) = do
  self <- getSelfPid
  promulgateEQ eqnids (SyncDumpToBS self) >>= flip withMonitor wait
  expect >>= \case
    SyncDumpToBSReply (Left err) -> do
      say $ "Dumping conf to " ++ fn ++ " failed with " ++ err
      liftIO exitFailure
    SyncDumpToBSReply (Right bs) -> do
      liftIO $ BS.writeFile fn bs
      say $ "Dumped conf in RG to this file " ++ fn
  where
    wait = void (expect :: Process ProcessMonitorNotification)

client :: [NodeId]
       -> ClientOptions
       -> Process ()
client eqnids (ClientStopOption fn reason) = do
  say "Trying to stop m0t1fs client."
  case strToFid fn of
    Just fid -> do
      promulgateEQ eqnids (StopMeroClientRequest fid reason) >>= flip withMonitor wait
      say "Command was delivered to EQ."
    Nothing -> do
      say "Incorrect Fid format."
      liftIO exitFailure
  where
    wait = void (expect :: Process ProcessMonitorNotification)
client eqnids (ClientStartOption fn) = do
  say "Trying to start m0t1fs client."
  case strToFid fn of
    Just fid -> do
      promulgateEQ eqnids (StartMeroClientRequest fid) >>= flip withMonitor wait
      say "Command was delivered to EQ."
    Nothing -> do
      say "Incorrect Fid format."
      liftIO exitFailure
  where
    wait = void (expect :: Process ProcessMonitorNotification)

clusterStartCommand :: [NodeId]
                    -> Bool
                    -> Process ()
clusterStartCommand eqnids False = do
  subscribeOnTo eqnids (Proxy :: Proxy ClusterStartResult)
  _ <- promulgateEQ eqnids ClusterStartRequest
  Published msg _ <- expect :: Process (Published ClusterStartResult)
  unsubscribeOnFrom eqnids (Proxy :: Proxy ClusterStartResult)
  liftIO $ do
    putStr $ prettyClusterStartResult msg
    case msg of
      ClusterStartOk        -> exitSuccess
      ClusterStartTimeout{} -> exitFailure
      ClusterStartFailure{} -> exitFailure
clusterStartCommand eqnids True = do
  _ <- promulgateEQ eqnids ClusterStartRequest
  liftIO $ putStrLn "Cluster start request sent."

clusterStopCommand :: [NodeId] -> StopOptions -> Process ()
clusterStopCommand nids (StopOptions silent async stopTimeout reason) = do
  say' "Stopping cluster."
  self <- getSelfPid
  clusterCommand nids Nothing (ClusterStopRequest reason) return >>= \case
    StateChangeFinished -> do
      say' "Cluster already stopped"
      -- Bail out early, do not start monitor which won't receive any
      -- messages.
      liftIO exitSuccess
    StateChangeStarted -> do
      say' "Cluster stop initiated."

  promulgateEQ nids (MonitorClusterStop self) >>= flip withMonitor wait
  case async of
    True -> return ()
    False -> do
      void . spawnLocal $ receiveTimeout stopTimeout [] >> usend self ()
      fix $ \loop -> void $ receiveWait
        [ match $ \() -> do
            say' $ "Giving up on waiting for cluster stop after " ++ show stopTimeout ++ "µs"
            liftIO exitFailure
        , match $ \csd -> do
            outputClusterStopDiff csd
            case _csp_cluster_stopped csd of
              Nothing -> loop
              Just ClusterStopOk -> liftIO exitSuccess
              Just ClusterStopFailed{} -> liftIO exitFailure
        ]
  where
    say' msg = if silent then return () else liftIO (putStrLn msg)
    wait = void (expect :: Process ProcessMonitorNotification)
    outputClusterStopDiff :: ClusterStopDiff -> Process ()
    outputClusterStopDiff ClusterStopDiff{..} = do
      let o `movedTo` n = show o ++ " -> " ++ show n
          formatChange obj os ns = showFid obj ++ ": " ++ os `movedTo` ns
          warn m = say' $ "Warning: " ++ m
      for_ _csp_procs $ \(p, o, n) -> say' $ formatChange p o n
      for_ _csp_servs $ \(s, o, n) -> say' $ formatChange s o n
      for_ _csp_disposition $ \(od, nd) -> do
        say' $ "Cluster disposition: " ++ od `movedTo` nd

      let (op, np) = _csp_progress
      when (op /= np) $ do
        say' $ printf "Progress: %.2f%% -> %.2f%%" (fromRational op :: Float) (fromRational np :: Float)

      for_ _csp_cluster_stopped $ \case
        ClusterStopOk -> say' "Cluster stopped successfully"
        ClusterStopFailed failMsg -> say' $ "Cluster stop failed: " ++ failMsg

      if op > np then warn "Cluster stop progress decreased!" else return ()
      for_ _csp_warnings $ \w -> warn w

clusterReset :: [NodeId]
             -> ResetOptions
             -> Process ()
clusterReset eqnids (ResetOptions hard unstick) = if unstick
  then do
    self <- getSelfPid
    eqs <- findEQFromNodes 1000000 eqnids
    case eqs of
      [] -> liftIO $ putStrLn "Cannot find EQ."
      eq:_ -> do
        nsendRemote eq eventQueueLabel $ DoClearEQ self
        msg <- expectTimeout 1000000
        case msg of
          Nothing -> liftIO $ putStrLn "No reply from EQ."
          Just DoneClearEQ -> liftIO $ putStrLn "EQ cleared."
    -- Attempt to kill the RC
    for_ eqnids $ \nid -> whereisRemoteAsync nid labelRecoveryCoordinator
    void . spawnLocal $ receiveTimeout 3000000 [] >> usend self ()
    fix $ \loop -> do
      void $ receiveWait
        [ matchIf (\(WhereIsReply s _) -> s == labelRecoveryCoordinator)
           $ \(WhereIsReply _ mp) -> case mp of
             Nothing -> loop
             Just p -> do
               liftIO $ putStrLn "Killing recovery coordinator."
               kill p "User requested `cluster reset --unstick`"
               liftIO exitSuccess
        , match $ \() -> liftIO $ do
            hPutStrLn stderr "Cannot determine the location of the RC."
            exitFailure
        ]
  else do
      promulgateEQ eqnids (ClusterResetRequest hard) >>= flip withMonitor wait
    where
      wait = void (expect :: Process ProcessMonitorNotification)

clusterCommand :: (SafeCopy a, Serializable a, Serializable b, Show b)
               => [NodeId]
               -> Maybe Int -- ^ Custom timeout in seconds, default 10s
               -> (SendPort b -> a)
               -> (b -> Process c)
               -> Process c
clusterCommand eqnids mt mk f = do
  (schan, rchan) <- newChan
  promulgateEQ eqnids (mk schan) >>= flip withMonitor wait
  let t = maybe 10000000 (* 1000000) mt
  receiveTimeout t [ matchChan rchan f ] >>= liftIO . \case
    Nothing -> do
      hPutStrLn stderr "Timed out waiting for cluster status reply from RC."
      exitFailure
    Just c -> return c
  where
    wait = void (expect :: Process ProcessMonitorNotification)

clusterStopNode :: [NodeId] -> StopNodeOptions -> Process ()
clusterStopNode eqnids opts = do
  case strToFid (stopNodeFid opts) of
    Nothing -> liftIO $ do
      hPutStrLn stderr "Not a fid"
      exitFailure
    Just fid -> do
      (schan, rchan) <- newChan
      subscribing $ do
         _ <- promulgateEQ eqnids $ StopNodeUserRequest
                fid (stopNodeForce opts) schan (stopNodeReason opts)
         r <- receiveChan rchan
         case r of
           NotANode{} ->liftIO $ do
             hPutStrLn stderr "Requested fid is not a node fid."
             exitFailure
           CantStop _ _ results -> liftIO $ do
             hPutStrLn stderr "Can't stop node because it leads to:"
             forM_ results $ \result -> hPutStrLn stderr $ "    " ++ result
             exitFailure
           StopInitiated _ node -> do
             liftIO $ putStrLn "Stop initiated."
             when (stopNodeSync opts) $ do
                liftIO $ putStrLn "Waiting for completion."
                fix $ \inner -> do
                  Published msg _ <- expect :: Process (Published MaintenanceStopNodeResult)
                  case msg of
                    MaintenanceStopNodeOk rnode | rnode /= node -> inner
                    MaintenanceStopNodeTimeout rnode | rnode /= node -> inner
                    MaintenanceStopNodeFailed rnode _ | rnode /= node -> inner
                    MaintenanceStopNodeOk{} -> liftIO $ putStrLn "Stop node finished."
                    MaintenanceStopNodeTimeout{} -> liftIO $ putStrLn "Stop node timeout."
                    MaintenanceStopNodeFailed _ err -> liftIO . putStrLn $ "Stop node failed: " ++ err
  where
   subscribing | stopNodeSync opts = bracket_
     (subscribeOnTo eqnids (Proxy :: Proxy MaintenanceStopNodeResult))
     (unsubscribeOnFrom eqnids (Proxy :: Proxy MaintenanceStopNodeResult))
               | otherwise = id

-- | Nicely format 'ClusterStartResult' into something the user can
-- easily understand.
prettyClusterStartResult :: ClusterStartResult -> String
prettyClusterStartResult = \case
  ClusterStartOk -> "Cluster started successfully.\n"
  ClusterStartTimeout ns -> unlines $
    "Cluster failed to start on time. Still waiting for following processes:"
    : map (\n -> formatNode n " (Timeout)") ns
  ClusterStartFailure s spn -> unlines $
    ("Cluster failed with “" ++ s ++ "” due to:")
    : mapMaybe formatSPNR spn
  where
    formatSPNR :: StartProcessesOnNodeResult -> Maybe String
    formatSPNR (NodeProcessesStartTimeout n ps) = Just $ formatNode (n, ps) " (Timeout)"
    formatSPNR (NodeProcessesStartFailure n ps) = Just $ formatNode (n, ps) " (Failure)"
    formatSPNR NodeProcessesStarted{}           = Nothing

    formatProcess :: (M0.Process, M0.ProcessState) -> String
    formatProcess (p, s) = "\t\t" ++ showFid p ++ ": " ++ show s

    formatNode (n, ps) m = unlines $ ("\t" ++ showFid n ++ m) : map formatProcess ps

prettyReport :: Bool -> ReportClusterState -> IO ()
prettyReport showDevices (ReportClusterState status sns info' mstats hosts) = do
  putStrLn $ "Cluster is " ++ maybe "N/A" M0.prettyStatus status
  case info' of
    Nothing -> putStrLn "cluster information is not available, load initial data.."
    Just (M0.Profile pfid, M0.Filesystem ffid _ _)  -> do
      putStrLn   "  cluster info:"
      putStrLn $ "    profile:    " ++ fidToStr pfid
      putStrLn $ "    filesystem: " ++ fidToStr ffid
      forM_ mstats $ \stats -> do
        putStrLn $ "    Filesystem stats:"
        putStrLn $ "      Total space: " ++ show (_fss_total_disk . M0._fs_stats $ stats)
        putStrLn $ "      Free space: " ++ show (_fss_free_disk . M0._fs_stats $ stats)
        putStrLn $ "      Total segments: " ++ show (_fss_total_seg . M0._fs_stats $ stats)
        putStrLn $ "      Free segments: " ++ show (_fss_free_seg . M0._fs_stats $ stats)
      unless (null sns) $ do
         putStrLn $ "    sns operations:"
         forM_ sns $ \(M0.Pool pool_fid, s) -> do
           putStrLn $ "      pool:" ++ fidToStr pool_fid ++ " => " ++ show (M0.prsType s)
           putStrLn $ "      uuid:" ++ show (M0.prsRepairUUID s)
           forM_ (M0.prsPri s) $ \i -> do
             putStrLn $ "      time of start: " ++ show (M0.priTimeOfSnsStart i)
             forM_ (M0.priStateUpdates i) $ \(M0.SDev{d_fid=sdev_fid,d_path=sdev_path},_) -> do
               putStrLn $ "          " ++ fidToStr sdev_fid ++ " -> " ++ sdev_path
      putStrLn $ "\nHosts:"
      forM_ hosts $ \(Castor.Host qfdn, ReportClusterHost m0fid st ps) -> do
         let (nst,extSt) = M0.displayNodeState st
         printf node_pattern nst (showNodeFid m0fid) qfdn
         for_ extSt $ printf node_pattern_ext (""::String)
         forM_ ps $ \( M0.Process{r_fid=rfid, r_endpoint=endpoint}
                     , ReportClusterProcess ptype proc_st srvs) -> do
           let (pst,proc_extSt) = M0.displayProcessState proc_st
           printf proc_pattern pst
                               (fidToStr rfid)
                               endpoint
                               ptype
           for_ proc_extSt $ printf proc_pattern_ext (""::String)
           for_ srvs $ \(ReportClusterService sst (M0.Service fid' t' _) sdevs) -> do
             let (serv_st,serv_extSt) = M0.displayServiceState sst
             printf serv_pattern serv_st
                                 (fidToStr fid')
                                 (show t')
             for_ serv_extSt $ printf serv_pattern_ext (""::String)
             when (showDevices && (not . null) sdevs) $ do
               putStrLn "    Devices:"
               forM_ sdevs $ \(M0.SDev{d_fid=sdev_fid,d_path=sdev_path}, sdev_st, mslot, msdev) -> do
                 let (sd_st,sdev_extSt) = M0.displaySDevState sdev_st
                 printf sdev_pattern sd_st
                                     (fidToStr sdev_fid)
                                     (maybe "No StorageDevice" show msdev)
                                     (sdev_path)
                 for_ sdev_extSt $ printf sdev_pattern_ext (""::String)
                 for_ mslot $ printf sdev_patterni (""::String) . show
   where
     showNodeFid Nothing = ""
     showNodeFid (Just (M0.Node fid)) = show fid
     node_pattern  = "  [%9s] %-24s  %s\n"
     node_pattern_ext  = "  %13s Extended state: %s\n"
     proc_pattern  = "  [%9s] %-24s    %s %s\n"
     proc_pattern_ext  = "  %13s Extended state: %s\n"
     serv_pattern  = "  [%9s] %-24s      %s\n"
     serv_pattern_ext  = "  %13s Extended state: %s\n"
     sdev_pattern  = "  [%9s] %-24s        %s %s\n"
     sdev_pattern_ext  = "  %13s Extended state: %s\n"
     sdev_patterni = "  %13s %s\n"

clusterHVarsUpdate :: [NodeId] -> VarsOptions -> Process ()
clusterHVarsUpdate eqnids (VarsSet{..}) = do
  (schan, rchan) <- newChan
  _ <- promulgateEQ eqnids (GetHalonVars schan) >>= flip withMonitor wait
  mc <- receiveTimeout 10000000 [ matchChan rchan return ]
  case mc of
    Nothing -> liftIO $ do
      hPutStrLn stderr "Failed to contact EQ in 10s."
      exitFailure
    Just  c ->
      let hv = foldr ($) c
                 [ maybe id (\s -> \x -> x{Castor._hv_recovery_expiry_seconds = s}) recoveryExpirySeconds
                 , maybe id (\s -> \x -> x{Castor._hv_recovery_max_retries = s}) recoveryMaxRetries
                 , maybe id (\s -> \x -> x{Castor._hv_keepalive_frequency = s}) keepaliveFrequency
                 , maybe id (\s -> \x -> x{Castor._hv_keepalive_timeout = s}) keepaliveTimeout
                 , maybe id (\s -> \x -> x{Castor._hv_drive_reset_max_retries = s}) driveResetMaxRetries
                 , maybe id (\s -> \x -> x{Castor._hv_disable_smart_checks = s}) disableSmartCheck
                 ]
      in promulgateEQ eqnids (Castor.SetHalonVars hv) >>= flip withMonitor wait
  where
    wait = void (expect :: Process ProcessMonitorNotification)
clusterHVarsUpdate _ VarsGet = return ()

jsonReport :: ReportClusterState -> IO ()
jsonReport = BSL.putStrLn . HA.Aeson.encode

runDriveCommand :: [NodeId] -> DriveCommand -> Process ()
runDriveCommand nids (DriveStatus serial slot@(Castor.Slot enc _) status) =
  clusterCommand nids Nothing (CommandStorageDeviceStatus serial slot status "NONE") $ \case
    StorageDeviceStatusErrorNoSuchDevice -> liftIO $ do
      putStrLn $ "Unkown drive " ++ serial
    StorageDeviceStatusErrorNoSuchEnclosure -> liftIO $ do
      putStrLn $ "can't find an enclosure " ++ show enc ++ " or node associated with it"
    StorageDeviceStatusUpdated -> liftIO $ do
      putStrLn $ "Command executed."
runDriveCommand nids (DrivePresence serial slot@(Castor.Slot enc _) isInstalled isPowered) =
  clusterCommand nids Nothing (CommandStorageDevicePresence serial slot isInstalled isPowered) $ \case
    StorageDevicePresenceErrorNoSuchDevice -> liftIO $ do
      putStrLn $ "Unknown drive " ++ serial
      exitFailure
    StorageDevicePresenceErrorNoSuchEnclosure -> liftIO $ do
      putStrLn $ "No enclosure " ++ show enc
      exitFailure
    StorageDevicePresenceUpdated -> liftIO $ do
      putStrLn $ "Command executed."
runDriveCommand nids (DriveNew serial path) =
  clusterCommand nids Nothing (CommandStorageDeviceCreate serial path) $ \case
   StorageDeviceErrorAlreadyExists -> liftIO $ do
     putStrLn $ "Drive already exists: " ++ serial
     exitFailure
   StorageDeviceCreated -> liftIO $ do
     putStrLn $ "Storage device created."
