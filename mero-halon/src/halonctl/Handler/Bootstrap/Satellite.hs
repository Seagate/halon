-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Satellite bootstrap module. When a satellite is started, it sends repeated
-- 'NodeUp' messages to the RC, which is then responsible for starting any
-- required services on the node.

{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Handler.Bootstrap.Satellite
  ( Config
  , schema
  , start
  )
where

import Prelude hiding ((<*>), (<$>))
import HA.NodeUp (nodeUp, nodeUp__static, nodeUp__sdict)
import Lookup (conjureRemoteNodeId)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
  ( mkClosure )

import Data.Binary (Binary)
import Data.Defaultable (Defaultable, defaultable, fromDefault)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Applicative ((<*>), (<$>))
import qualified Options.Applicative as Opt

data Config = Config
  { configTrackers :: Defaultable [String]
  , configDelay :: Defaultable Int
  } deriving (Eq, Show, Ord, Generic, Typeable)

instance Binary Config
instance Hashable Config

schema :: Opt.Parser Config
schema = let
    trackers = defaultable [] . Opt.many . Opt.strOption
             $ Opt.long "trackers"
            <> Opt.short 't'
            <> Opt.help "Addresses of tracking station nodes."
            <> Opt.metavar "ADDRESSES"
    pingDelay = defaultable 10000000 . (Opt.option Opt.auto)
             $ Opt.long "pingDelay"
            <> Opt.short 'd'
            <> Opt.help ("Time between sending NodeUp messages"
                          ++ "to the tracking station (ms).")
            <> Opt.metavar "DELAY"
  in Config <$> trackers <*> pingDelay

self :: String
self = "HA.Satellite"

start :: NodeId -> Config -> Process ()
start nid Config{..} = do
    say $ "This is " ++ self
    _ <- spawn nid $ $(mkClosure 'nodeUp) (
                          trackers
                        , fromDefault configDelay)
#ifdef USE_RPC
    -- The RPC transport triggers a bug in spawn where the action never
    -- executes.
    _ <- receiveTimeout 1000000 [] :: Process (Maybe ())
#endif
    return ()
  where
    trackers = fmap conjureRemoteNodeId (fromDefault configTrackers)


