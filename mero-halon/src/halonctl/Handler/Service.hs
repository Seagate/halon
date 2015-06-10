-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

--  Handler for the 'service' command, used to start, stop and query service
--  status.
module Handler.Service
  ( ServiceCmdOptions
  , service
  , parseService
  )
where

import Prelude hiding ((<$>), (<*>))
import HA.EventQueue.Producer (promulgateEQ)
import HA.Resources
  ( Node(..) )
import HA.Service
import qualified HA.Services.DecisionLog as DLog
import qualified HA.Services.Dummy       as Dummy
import qualified HA.Services.Frontier    as Frontier
#ifdef USE_MERO
import qualified HA.Services.Mero        as Mero
#endif
import qualified HA.Services.Noisy       as Noisy
import qualified HA.Services.SSPL        as SSPL
import qualified HA.Services.SSPLHL      as SSPLHL

import Lookup (conjureRemoteNodeId)

import Control.Applicative ((<|>))
import Control.Distributed.Process
  ( NodeId
  , Process
  , ProcessMonitorNotification
  , expect
  , withMonitor
  , liftIO
  )
import Control.Monad (void)

import Data.Binary
  ( Binary )
import Data.Typeable
  ( Typeable )
import GHC.Generics
  ( Generic )

import Options.Applicative
    ( (<$>)
    , (<*>)
    , (<>)
    )
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O
import Options.Schema.Applicative (mkParser)

-- | Options for the "service" command. Typically this will be a subcommand
--   corresponding to operating on a particular service.
data ServiceCmdOptions =
      DummyServiceCmd (StandardServiceOptions Dummy.DummyConf)
    | NoisyServiceCmd (StandardServiceOptions Noisy.NoisyConf)
    | SSPLServiceCmd (StandardServiceOptions SSPL.SSPLConf)
    | SSPLHLServiceCmd (StandardServiceOptions SSPLHL.SSPLHLConf)
    | FrontierServiceCmd (StandardServiceOptions Frontier.FrontierConf)
    | DLogServiceCmd (StandardServiceOptions DLog.DecisionLogConf)
#ifdef USE_MERO
    | MeroServiceCmd (StandardServiceOptions Mero.MeroConf)
#endif
  deriving (Eq, Show, Generic, Typeable)

-- | Options for a 'standard' service. This consists of a set of subcommands
--   to carry out particular operations.
data StandardServiceOptions a =
      StartCmd (StartCmdOptions a) -- ^ Start an instance of the service.
    | ReconfCmd (ReconfCmdOptions a)
    | StopCmd (StopCmdOptions a)
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StandardServiceOptions a)

-- | Options relevant to starting a service.
data StartCmdOptions a =
    StartCmdOptions
      [String] -- ^ EQ Nodes
      a -- ^ Configuration
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StartCmdOptions a)

-- | Options relevant to reconfiguring a service.
data ReconfCmdOptions a =
    ReconfCmdOptions
      [String] -- ^ EQ Nodes
      a -- ^ Configuration
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (ReconfCmdOptions a)

-- | Options relevant to stopping a service.
data StopCmdOptions a =
    StopCmdOptions
    [String] -- ^ EQ Nodes
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StopCmdOptions a)

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
    startCmd = O.command "start" $ StartCmd <$>
                (O.withDesc
                  (StartCmdOptions
                    <$> tsNodes
                    <*> mkParser schema)
                  "Start the service on a node.")
    reconfCmd = O.command "reconfigure" $ ReconfCmd <$>
                (O.withDesc
                  (ReconfCmdOptions
                    <$> tsNodes
                    <*> mkParser schema)
                  "Reconfigure the service on a node.")
    stopCmd = O.command "stop" $ StopCmd <$>
              (O.withDesc
                (StopCmdOptions <$> tsNodes)
                "Stop the service on a node.")
  in O.command (snString . serviceName $ svc) (O.withDesc
      ( O.subparser
      $  startCmd
      <> reconfCmd
      <> stopCmd
      )
      ("Control the " ++ (snString . serviceName $ svc) ++ " service."))

-- | Parse the options for the "service" command.
parseService :: O.Parser ServiceCmdOptions
parseService =
    (DummyServiceCmd <$> (O.subparser $
         mkStandardServiceCmd Dummy.dummy)
    ) <|>
    (NoisyServiceCmd <$> (O.subparser $
         mkStandardServiceCmd Noisy.noisy)
    ) <|>
    (SSPLServiceCmd <$> (O.subparser $
         mkStandardServiceCmd SSPL.sspl)
    ) <|>
    (SSPLHLServiceCmd <$> (O.subparser $
         mkStandardServiceCmd SSPLHL.sspl)
    ) <|>
    (FrontierServiceCmd <$> (O.subparser $
         mkStandardServiceCmd Frontier.frontier)
    ) <|>
    (DLogServiceCmd <$> (O.subparser $
         mkStandardServiceCmd DLog.decisionLog)
    )
#ifdef USE_MERO
    <|> (MeroServiceCmd <$> (O.subparser $
         mkStandardServiceCmd Mero.m0d))
#endif

-- | Handle the "service" command.
--   The "service" command is basically a wrapper around a number of commands
--   for individual services (e.g. dummy service, m0 service). Often these
--   will follow 'standard service' structure.
service :: [NodeId] -- ^ NodeIds of the nodes to control services on.
        -> ServiceCmdOptions
        -> Process ()
service nids so = case so of
  DummyServiceCmd sso    -> standardService nids sso Dummy.dummy
  NoisyServiceCmd sso    -> standardService nids sso Noisy.noisy
  SSPLServiceCmd sso     -> standardService nids sso SSPL.sspl
  SSPLHLServiceCmd sso   -> standardService nids sso SSPLHL.sspl
  FrontierServiceCmd sso -> standardService nids sso Frontier.frontier
  DLogServiceCmd sso     -> standardService nids sso DLog.decisionLog
#ifdef USE_MERO
  MeroServiceCmd sso     -> standardService nids sso Mero.m0d
#endif

-- | Handle an instance of a "standard service" command.
standardService :: Configuration a
              => [NodeId] -- ^ NodeIds of the nodes to control services on.
              -> StandardServiceOptions a
              -> Service a
              -> Process ()
standardService nids sso svc = case sso of
  StartCmd (StartCmdOptions eqAddrs a) -> mapM_ (start svc a eqAddrs) nids
  ReconfCmd (ReconfCmdOptions eqAddrs a) -> mapM_ (reconf svc a eqAddrs) nids
  StopCmd (StopCmdOptions eqAddrs) -> mapM_ (stop svc eqAddrs) nids

-- | Start a given service on a single node.
start :: Configuration a
      => Service a -- ^ Service to start.
      -> a -- ^ Configuration.
      -> [String] -- ^ EQ Nodes to send start messages to.
      -> NodeId -- ^ Node on which to start the service.
      -> Process ()
start s c eqAddrs nid = do
    liftIO $ putStrLn $ "Try to start " ++ (show $ serviceName s)
    promulgateEQ eqnids ssrm
    >>= \pid -> withMonitor pid wait
  where
    eqnids = fmap conjureRemoteNodeId eqAddrs
    ssrm = encodeP $ ServiceStartRequest Start (Node nid) s c
    wait = void (expect :: Process ProcessMonitorNotification)

-- | Reconfigure a service
reconf :: Configuration a
       => Service a -- ^ Service to reconfigure.
       -> a -- ^ Configuration.
       -> [String] -- ^ EQ Nodes to contact.
       -> NodeId -- ^ Filter for which instances to reconfigure.
       -> Process ()
reconf s c eqAddrs nid = promulgateEQ eqnids msg
    >>= \pid -> withMonitor pid wait
  where
    eqnids = fmap conjureRemoteNodeId eqAddrs
    msg = encodeP $ ServiceStartRequest Restart (Node nid) s c
    wait = void (expect :: Process ProcessMonitorNotification)

-- | Stop a given service on a single node.
stop :: Configuration a
     => Service a -- ^ Service to stop.
     -> [String] -- ^ EQ Nodes to send stop messages to.
     -> NodeId -- ^ Node on which to stop the service.
     -> Process ()
stop s eqAddrs nid = promulgateEQ eqnids ssrm
    >>= \pid -> withMonitor pid wait
  where
    eqnids = fmap conjureRemoteNodeId eqAddrs
    ssrm = encodeP $ ServiceStopRequest (Node nid) s
    wait = void (expect :: Process ProcessMonitorNotification)
