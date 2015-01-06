-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Tracking station bootstrap module. This serves to start recovery supervisors
-- on a set of provided nodes.

{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Handler.Bootstrap.TrackingStation
  ( Config
  , schema
  , start
  )
where

import Control.Distributed.Process
  ( Process
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

import Options.Applicative ((<*>), (<$>))
import qualified Options.Applicative as Opt

import HA.RecoveryCoordinator.Mero.Startup

data Config = Config
  { configUpdate :: Defaultable Bool
  , configTrackers :: Defaultable [String]
  , configSatellites :: Defaultable [String]
  } deriving (Eq, Show, Ord, Generic, Typeable)

instance Binary Config
instance Hashable Config

schema :: Opt.Parser Config
schema = let
    upd = defaultable False . Opt.switch
             $ Opt.long "update"
            <> Opt.short 'u'
            <> Opt.help "Update something."
    trackers = defaultable [] . Opt.many . Opt.strOption
             $ Opt.long "trackers"
            <> Opt.short 't'
            <> Opt.help "Addresses to spawn tracking station nodes on."
            <> Opt.metavar "ADDRESSES"
    sats = defaultable [] . Opt.many . Opt.strOption
             $ Opt.long "satellites"
            <> Opt.short 's'
            <> Opt.help "Satellite node addresses (not including trackers)."
            <> Opt.metavar "ADDRESSES"
  in Config <$> upd <*> trackers <*> sats

self :: String
self = "HA.TrackingStation"

start :: Config -> Process ()
start naConf = do
    say $ "This is " ++ self
    nid <- getSelfNode
    result <- call $(functionTDict 'ignition) nid $
               $(mkClosure 'ignition) args
    case result of
      Just (added, trackers, members, newNodes) -> liftIO $ do
        if added then do
          putStrLn "The following nodes joined successfully:"
          mapM_ print newNodes
        else
          putStrLn "No new node could join the group."
        putStrLn ""
        putStrLn "The following nodes were already in the group:"
        mapM_ print members
        putStrLn ""
        putStrLn "The following nodes could not be contacted:"
        mapM_ print $ trackers
      Nothing -> return ()
  where
    args = ( fromDefault . configUpdate $ naConf
           , fromDefault . configTrackers $ naConf
           , fromDefault . configSatellites $ naConf
           )
