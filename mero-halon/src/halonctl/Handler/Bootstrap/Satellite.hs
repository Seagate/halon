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
  ( Config(..)
  , defaultConfig
  , schema
  , start
  , startSatellitesAsync
  )
where

import HA.NodeUp (nodeUp, nodeUp__static, nodeUp__sdict)
import Lookup (conjureRemoteNodeId)

import Control.Monad.Reader (ask)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
  ( mkClosure )
import Control.Distributed.Process.Node (forkProcess)
import Control.Distributed.Process.Internal.Types (processNode)

import Data.Binary (Binary)
import Data.Defaultable (Defaultable(..), defaultable, fromDefault)
import Data.Foldable (forM_)
import Data.Hashable (Hashable)
import Data.Maybe (catMaybes)
import Data.Monoid ((<>))
import Data.Traversable (forM)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)
import qualified Options.Applicative as Opt

data Config = Config
  { configTrackers :: Defaultable [String]
  } deriving (Eq, Show, Ord, Generic, Typeable)

instance Binary Config
instance Hashable Config

defaultConfig :: Config
defaultConfig = Config (Default [])

schema :: Opt.Parser Config
schema = let
    trackers = defaultable [] . Opt.many . Opt.strOption
             $ Opt.long "trackers"
            <> Opt.short 't'
            <> Opt.help "Addresses of tracking station nodes."
            <> Opt.metavar "ADDRESSES"
  in Config <$> trackers

selfName :: String
selfName = "HA.Satellite"

start :: NodeId -> Config -> Process (Maybe String)
start nid Config{..} = do
    say $ "This is " ++ selfName
    (sender, mref) <- spawnMonitor nid $ $(mkClosure 'nodeUp) trackers
#ifdef USE_RPC
    -- The RPC transport triggers a bug in spawn where the action never
    -- executes.
    _ <- receiveTimeout 1000000 [] :: Process (Maybe ())
#endif
    result <- receiveTimeout 5000000
      [ matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref) handler ]
    case result of
      Nothing -> do
        kill sender "timeout.."
        say $ "Failed to connect to the cluster, retrying.."
        (_, mref2) <- spawnMonitor nid $ $(mkClosure 'nodeUp) trackers
        result2 <- receiveTimeout 5000000
           [ matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref2) handler ]
        case result2 of
          Nothing -> return (Just "Timeout.")
          Just x  -> return x
      Just r -> return r
  where
    trackers = fmap conjureRemoteNodeId (fromDefault configTrackers)
    handler (ProcessMonitorNotification _ _ dr) = return $ case dr of
      DiedException e -> Just e
      _ -> Nothing

-- Fork start process, wait for results from each, output
-- information about any failures.
startSatellitesAsync :: Config -> [NodeId] -> Process [(NodeId, String)]
startSatellitesAsync conf nids = do
  self <- getSelfPid
  localNode <- fmap processNode ask
  liftIO . forM_ nids $ \nid -> do
    forkProcess localNode $ do
      res <- start nid conf
      usend self $ (nid,) <$> res
  catMaybes <$> forM nids (const expect)
