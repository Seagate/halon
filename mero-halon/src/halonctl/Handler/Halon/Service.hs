{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE StrictData                 #-}
-- |
-- Module    : Handler.Halon.Service
-- Copyright : (C) 2014-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Handler for the 'service' command, used to start, stop and query
-- service status.
module Handler.Halon.Service
  ( Options(..)
  , service
  , parser
  , start
  ) where


import           Control.Applicative ((<|>))
import           Control.Distributed.Process
  ( NodeId
  , Process
  , ProcessMonitorNotification
  , expect
  , expectTimeout
  , getSelfPid
  , withMonitor
  , liftIO
  )
import           Control.Monad (void)
import           Data.Aeson.Encode.Pretty
import           Data.Binary ( Binary )
import qualified Data.ByteString.Lazy.Char8 as B8
import           Data.Monoid ((<>))
import           Data.Typeable ( Typeable )
import           GHC.Generics ( Generic )
import           HA.Encode
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.Service.Events
import           HA.Resources ( Node(..) )
import           HA.Service
import qualified HA.Services.DecisionLog as DLog
import qualified HA.Services.Dummy as Dummy
import qualified HA.Services.Ekg as Ekg
import qualified HA.Services.Mero as Mero
import qualified HA.Services.Noisy as Noisy
import qualified HA.Services.Ping as Ping
import qualified HA.Services.SSPL as SSPL
import qualified HA.Services.SSPLHL as SSPLHL
import           Lookup
import           Options.Applicative ((<$>), (<*>))
import qualified Options.Applicative as O
import           Options.Applicative.Extras (command')
import           Options.Schema.Applicative (mkParser)
import           Prelude hiding ((<$>), (<*>))

-- | Options for the "service" command. Typically this will be a subcommand
--   corresponding to operating on a particular service.
data Options =
      DummyServiceCmd (StandardServiceOptions Dummy.DummyConf)
    | NoisyServiceCmd (StandardServiceOptions Noisy.NoisyConf)
    | PingServiceCmd (StandardServiceOptions Ping.PingConf)
    | SSPLServiceCmd (StandardServiceOptions SSPL.SSPLConf)
    | SSPLHLServiceCmd (StandardServiceOptions SSPLHL.SSPLHLConf)
    | DLogServiceCmd (StandardServiceOptions DLog.DecisionLogConf)
    | EkgServiceCmd (StandardServiceOptions Ekg.EkgConf)
    | MeroServiceCmd (StandardServiceOptions Mero.MeroConf)
  deriving (Eq, Show, Generic, Typeable)

-- | Options for a 'standard' service. This consists of a set of subcommands
--   to carry out particular operations.
data StandardServiceOptions a =
      StartCmd (StartCmdOptions a) -- ^ Start an instance of the service.
    | ReconfCmd (ReconfCmdOptions a)
    | StopCmd (StopCmdOptions a)
    | StatusCmd (StatusCmdOptions)
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StandardServiceOptions a)

-- | Options relevant to starting a service.
data StartCmdOptions a =
    StartCmdOptions
      Int -- ^ EQT Query timeout
      [String] -- ^ EQ Nodes
      a -- ^ Configuration
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StartCmdOptions a)

-- | Options relevant to reconfiguring a service.
data ReconfCmdOptions a =
    ReconfCmdOptions
      Int -- ^ EQT Query timeout
      [String] -- ^ EQ Nodes
      a -- ^ Configuration
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (ReconfCmdOptions a)

-- | Options relevant to stopping a service.
data StopCmdOptions a =
    StopCmdOptions
    Int -- ^ EQT Query timeout
    [String] -- ^ EQ Nodes
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StopCmdOptions a)

data StatusCmdOptions = StatusCmdOptions
    Int -- ^ EQT query timeout
    [String] -- ^ EQ nodes
  deriving (Eq, Show, Typeable, Generic)

instance Binary (StatusCmdOptions)

-- | Construct a command for a 'standard' service, consisting of the usual
--   start, stop and status subcommands.
mkStandardServiceCmd :: Configuration a
                 => Service a
                 -> O.Mod O.CommandFields (StandardServiceOptions a)
mkStandardServiceCmd svc = let
    tsNodes = O.many . O.strOption $
                           O.metavar "ADDRESSES"
                        <> O.long "trackers"
                        <> O.short 't'
                        <> O.help "Addresses of Tracking Station nodes."
    eqtTimeout = O.option O.auto $
                     O.metavar "TIMEOUT (μs)"
                  <> O.long "eqt-timeout"
                  <> O.value 1000000
                  <> O.help ("Time to wait from a reply from the EQT when" ++
                              " querying the location of an EQ.")
    startCmd = command' "start"
                  (StartCmd <$> (StartCmdOptions
                                 <$> eqtTimeout
                                 <*> tsNodes
                                 <*> mkParser schema))
                  "Start the service on a node."
    reconfCmd = command' "reconfigure"
                  (ReconfCmd <$> (ReconfCmdOptions
                                  <$> eqtTimeout
                                  <*> tsNodes
                                  <*> mkParser schema))
                  "Reconfigure the service on a node."
    stopCmd = command' "stop"
                  (StopCmd <$> (StopCmdOptions
                                <$> eqtTimeout
                                <*> tsNodes))
                  "Stop the service on a node."
    statusCmd = command' "status"
                  (StatusCmd <$> (StatusCmdOptions
                                  <$> eqtTimeout
                                  <*> tsNodes))
                  "Query the status of a service on a node."
  in command' (serviceName svc)
       ( O.hsubparser
       $ startCmd
      <> reconfCmd
      <> stopCmd
      <> statusCmd )
       ("Control the " ++ (serviceName svc) ++ " service.")

-- | Parse the options for the "service" command.
parser :: O.Parser Options
parser =
    (DummyServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd Dummy.dummy)
    ) <|>
    (NoisyServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd Noisy.noisy)
    ) <|>
    (PingServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd Ping.ping)
    ) <|>
    (SSPLServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd SSPL.sspl)
    ) <|>
    (SSPLHLServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd SSPLHL.sspl)
    ) <|>
    (DLogServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd DLog.decisionLog)
    ) <|>
    (EkgServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd Ekg.ekg)
    ) <|>
    (MeroServiceCmd <$> (O.hsubparser $
         mkStandardServiceCmd Mero.m0d_real)
    )

-- | Handle the "service" command.
--   The "service" command is basically a wrapper around a number of commands
--   for individual services (e.g. dummy service, m0 service). Often these
--   will follow 'standard service' structure.
service :: [NodeId] -- ^ NodeIds of the nodes to control services on.
        -> Options
        -> Process ()
service nids so = case so of
  DummyServiceCmd sso    -> standardService nids sso Dummy.dummy
  NoisyServiceCmd sso    -> standardService nids sso Noisy.noisy
  PingServiceCmd sso    -> standardService nids sso Ping.ping
  SSPLServiceCmd sso     -> standardService nids sso SSPL.sspl
  SSPLHLServiceCmd sso   -> standardService nids sso SSPLHL.sspl
  DLogServiceCmd sso     -> standardService nids sso DLog.decisionLog
  EkgServiceCmd sso      ->standardService nids sso Ekg.ekg
  MeroServiceCmd sso     -> standardService nids sso Mero.m0d_real

-- | Handle an instance of a "standard service" command.
standardService :: Configuration a
              => [NodeId] -- ^ NodeIds of the nodes to control services on.
              -> StandardServiceOptions a
              -> Service a
              -> Process ()
standardService nids sso svc = case sso of
  StartCmd (StartCmdOptions t eqAddrs a) -> getEQAddrs t eqAddrs >>= \eqs ->
                                            mapM_ (start t svc a eqs) nids
  ReconfCmd (ReconfCmdOptions t eqAddrs a) -> getEQAddrs t eqAddrs >>= \eqs ->
                                              mapM_ (reconf t svc a eqs) nids
  StopCmd (StopCmdOptions t eqAddrs) -> getEQAddrs t eqAddrs >>= \eqs ->
                                        mapM_ (stop svc eqs) nids
  StatusCmd (StatusCmdOptions t eqAddrs) -> do
    eqs <- getEQAddrs t eqAddrs
    resp <- mapM (status t svc eqs) nids
    let stat = zip nids resp
    mapM_ (liftIO . putStrLn . showStatus) stat
  where
    getEQAddrs timeout eqs = case eqs of
      [] -> findEQFromNodes timeout nids
      _ -> return $ fmap conjureRemoteNodeId eqs
    showStatus (nid, Nothing) = show nid ++ ": No reply."
    showStatus (nid, Just SrvStatNotRunning) =
      show nid ++ ": Service not running."
    showStatus (nid, Just (SrvStatStillRunning pid)) =
      show nid ++ ": Is not registered but still running on " ++ show pid
    showStatus (nid, Just (SrvStatError msg)) =
      show nid ++ ": Error: " ++ msg
    showStatus (nid, Just (SrvStatRunning _ pid a)) =
      show nid ++ ": Running on PID " ++ show pid
                ++ " with config:\n" ++ B8.unpack (encodePretty a)
    showStatus (nid, Just (SrvStatFailed _ a)) =
      show nid ++ ": Not running "
               ++ " but configured with:\n" ++ B8.unpack (encodePretty a)

-- | Start a given service on a single node.
start :: Configuration a
      => Int -- ^ timeout
      -> Service a -- ^ Service to start.
      -> a -- ^ Configuration.
      -> [NodeId] -- ^ EQ Nodes to send start messages to.
      -> NodeId -- ^ Node on which to start the service.
      -> Process ()
start t s c eqnids nid = do
    self <- getSelfPid
    promulgateEQ eqnids (ssrm self) >>= \pid -> withMonitor pid wait
  where
    ssrm self = encodeP $ ServiceStartRequest Start (Node nid) s c [self]
    wait = do
      _ <- expect :: Process ProcessMonitorNotification
      stat <- expectTimeout t
      liftIO . putStrLn $ case stat of
        Just AlreadyRunning -> "Service already running."
        Just AttemptingToStart -> "Trying to start " ++ serviceName s
        Just NodeUnknown -> "Cannot start service on unknown node " ++ show nid
        Just x -> "error: " ++ show x
        Nothing -> "No service status reply after " ++ show t ++ " microseconds."

-- | Reconfigure a service
reconf :: Configuration a
       => Int
       -> Service a -- ^ Service to reconfigure.
       -> a -- ^ Configuration.
       -> [NodeId] -- ^ EQ Nodes to contact.
       -> NodeId -- ^ Node to reconfigure.
       -> Process ()
reconf t s c eqnids nid = promulgateEQ eqnids msg
    >>= \pid -> withMonitor pid wait
  where
    msg = encodeP $ ServiceStartRequest Restart (Node nid) s c []
    wait = do
      _ <- expect :: Process ProcessMonitorNotification
      stat <- expectTimeout t
      liftIO . putStrLn $ case stat of
        Just AttemptingToRestart -> "Trying to restart " ++ serviceName s
        Just NodeUnknown -> "Cannot restart service on unknown node " ++ show nid
        Just x -> "error: " ++ show x
        Nothing -> "No service status reply after " ++ show t ++ " microseconds."

-- | Stop a given service on a single node.
stop :: Configuration a
     => Service a -- ^ Service to stop.
     -> [NodeId] -- ^ EQ Nodes to send stop messages to.
     -> NodeId -- ^ Node on which to stop the service.
     -> Process ()
stop s eqnids nid = promulgateEQ eqnids ssrm
    >>= \pid -> withMonitor pid wait
  where
    ssrm = encodeP $ ServiceStopRequest (Node nid) s
    wait = void (expect :: Process ProcessMonitorNotification)

status :: Configuration a
       => Int
       -> Service a
       -> [NodeId]
       -> NodeId
       -> Process (Maybe ServiceStatusResponse)
status t s eqnids nid = do
    self <- getSelfPid
    promulgateEQ eqnids (msg self) >>= \pid -> withMonitor pid wait
  where
    msg self = encodeP $ ServiceStatusRequest (Node nid) s [self]
    wait = do
      _ <- expect :: Process ProcessMonitorNotification
      expectTimeout t >>= mapM decodeP
