-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Tracking station bootstrap module. This serves to start recovery supervisors
-- on a set of provided nodes.

{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module Handler.Bootstrap.TrackingStation
  ( Config
  , schema
  , start
  )
where

import Control.Distributed.Process
  ( Process
  , NodeId
  , call
  , getSelfNode
  , liftIO
  , say
  )
import Control.Distributed.Process.Closure ( mkClosure, functionTDict )

import Data.Binary (Binary)
import Data.Defaultable (Defaultable, defaultable, fromDefault)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Applicative ((<$>), (<*>))
import qualified Options.Applicative as Opt

import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.Startup

data Config = Config
  { configUpdate :: Defaultable Bool
  , configSnapshotsThreshold :: Defaultable Int
  } deriving (Eq, Show, Ord, Generic, Typeable)

instance Binary Config
instance Hashable Config

schema :: Opt.Parser Config
schema = let
    upd = defaultable False . Opt.switch
             $ Opt.long "update"
            <> Opt.short 'u'
            <> Opt.help "Update something."
    snapshotThreshold = defaultable 1000 . Opt.option Opt.auto
             $ Opt.long "snapshots-threshold"
            <> Opt.long "snapshot-threshold"
            <> Opt.short 'n'
            <> Opt.help ("Tells the amount of updates which are allowed " ++
                         "between snapshots of the distributed state."
                        )
            <> Opt.metavar "INTEGER"
  in Config <$> upd <*> snapshotThreshold

self :: String
self = "HA.TrackingStation"

start :: [NodeId] -- ^ Nodes on which to start the tracking station
      -> Config -> Process ()
start nids naConf = do
    say $ "This is " ++ self
    nid <- getSelfNode
    result <- call $(functionTDict 'ignition) nid $
               $(mkClosure 'ignition) args
    case result of
      Just (added, _, members, newNodes) -> liftIO $ do
        if added then do
          putStrLn "The following nodes joined successfully:"
          mapM_ print newNodes
        else
          putStrLn "No new node could join the group."
        putStrLn ""
        putStrLn "The following nodes were already in the group:"
        mapM_ print members
      Nothing -> return ()
  where
    args = ( fromDefault . configUpdate $ naConf
           , nids
           , fromDefault . configSnapshotsThreshold $ naConf
           , $(mkClosure 'recoveryCoordinator) $ IgnitionArguments nids
           )
