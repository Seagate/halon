-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--

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

import HA.EventQueue.Producer (promulgateEQ)
import HA.Resources (Node(..))
import HA.Service
import qualified HA.Services.Dummy as Dummy

import Lookup (conjureRemoteNodeId)

import Control.Distributed.Process
  ( NodeId
  , Process
  , ProcessMonitorNotification
  , expect
  , withMonitor
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
    DummyServiceCmd (StandardServiceOptions ())
  deriving (Eq, Show, Generic, Typeable)

-- | Options for a 'standard' service. This consists of a set of subcommands
--   to carry out particular operations.
data StandardServiceOptions a =
    StartCmd (StartCmdOptions a) -- ^ Start an instance of the service.
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StandardServiceOptions a)

-- | Options relevant to starting a service.
data StartCmdOptions a =
    StartCmdOptions
      [String] -- ^ EQ Nodes
      a -- ^ Configuration
  deriving (Eq, Show, Typeable, Generic)

instance Binary a => Binary (StartCmdOptions a)

-- | Construct a command for a 'standard' service, consisting of the usual
--   start, stop and status subcommands.
mkStandardServiceCmd :: Configuration a
                 => Service a
                 -> O.Mod O.CommandFields (StandardServiceOptions a)
mkStandardServiceCmd svc = let
    startCmd = O.command "start"
                (O.withDesc
                  (StartCmdOptions
                    <$> (O.many . O.strOption $
                           O.metavar "ADDRESSES"
                        <> O.long "trackers"
                        <> O.short 't'
                        <> O.help "Addresses of Tracking Station nodes.")
                    <*> mkParser schema)
                  "Start the service on a node.")
  in O.command (serviceName svc) (O.withDesc
      (StartCmd <$> O.subparser startCmd)
      ("Control the " ++ (serviceName svc) ++ " service."))

-- | Parse the options for the "service" command.
parseService :: O.Parser ServiceCmdOptions
parseService =
    DummyServiceCmd <$> (O.subparser $
         mkStandardServiceCmd Dummy.dummy)

-- | Handle the "service" command.
--   The "service" command is basically a wrapper around a number of commands
--   for individual services (e.g. dummy service, m0 service). Often these
--   will follow 'standard service' structure.
service :: [NodeId] -- ^ NodeIds of the nodes to control services on.
        -> ServiceCmdOptions
        -> Process ()
service nids so = case so of
  DummyServiceCmd sso -> standardService nids sso Dummy.dummy

-- | Handle an instance of a "standard service" command.
standardService :: Configuration a
              => [NodeId] -- ^ NodeIds of the nodes to control services on.
              -> StandardServiceOptions a
              -> Service a
              -> Process ()
standardService nids sso svc = case sso of
  StartCmd (StartCmdOptions eqAddrs a) -> mapM_ (start svc a eqAddrs) nids

-- | Start a given service on a single node.
start :: Configuration a
      => Service a -- ^ Service to start.
      -> a -- ^ Configuration.
      -> [String] -- ^ EQ Nodes to send start messages to.
      -> NodeId -- ^ Node on which to start the service.
      -> Process ()
start s c eqAddrs nid = promulgateEQ eqnids ssrm
    >>= \pid -> withMonitor pid wait
  where
    eqnids = fmap conjureRemoteNodeId eqAddrs
    ssrm = encodeP $ ServiceStartRequest (Node nid) s c
    wait = void (expect :: Process ProcessMonitorNotification)
