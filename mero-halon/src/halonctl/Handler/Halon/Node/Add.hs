{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData      #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : Handler.Halon.Node.Add
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Satellite bootstrap module. When a satellite is started, it sends
-- repeated 'NodeUp' messages to the RC, which is then responsible for
-- starting any required services on the node.
module Handler.Halon.Node.Add
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Internal.Types (processNode)
import           Control.Distributed.Process.Node (forkProcess)
import           Control.Monad.Reader (ask)
import           Data.Binary (Binary)
import           Data.Defaultable (Defaultable(..), defaultable, fromDefault)
import           Data.Foldable
import           Data.Hashable (Hashable)
import           Data.Maybe (catMaybes)
import           Data.Monoid ((<>))
import           Data.Traversable
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.NodeUp (nodeUp, nodeUp__static, nodeUp__sdict)
import           Lookup (conjureRemoteNodeId)
import qualified Options.Applicative as Opt

data Options = Options
  { configTrackers :: Defaultable [String]
  } deriving (Eq, Show, Ord, Generic, Typeable)

instance Binary Options
instance Hashable Options

parser :: Opt.Parser Options
parser = let
    trackers = defaultable [] . Opt.many . Opt.strOption
             $ Opt.long "trackers"
            <> Opt.short 't'
            <> Opt.help "Addresses of tracking station nodes."
            <> Opt.metavar "ADDRESSES"
  in Options <$> trackers

selfName :: String
selfName = "HA.Satellite"

start :: NodeId -> Options -> Process (Maybe String)
start nid Options{..} = do
    say $ "This is " ++ selfName
    (sender, mref) <- spawnMonitor nid $ $(mkClosure 'nodeUp) trackers
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
run :: [NodeId] -> Options -> Process [(NodeId, String)]
run nids conf = do
  self <- getSelfPid
  localNode <- fmap processNode ask
  liftIO . forM_ nids $ \nid -> do
    forkProcess localNode $ do
      res <- start nid conf
      usend self $ (nid,) <$> res
  catMaybes <$> forM nids (const expect)
