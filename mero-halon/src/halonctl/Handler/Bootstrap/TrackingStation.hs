-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
--------------------------------------------------------------------------------

{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Tracking station bootstrap module. This serves to start recovery
--   supervisors on a set of provided nodes.
module Handler.Bootstrap.TrackingStation
  ( TrackingStationOpts
  , tsSchema
  , startTS
  )
where

import Control.Distributed.Process
  ( Process
  , NodeId
  , call
  , liftIO
  , say
  , spawnLocal
  )
import Control.Distributed.Process.Closure ( mkClosure, functionTDict )
import Control.Monad (void)

import Data.Binary (Binary)
import Data.Defaultable (Defaultable, defaultable, fromDefault)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Applicative ((<*>), (<$>))
import qualified Options.Applicative as Opt

import HA.RecoveryCoordinator.Mero.Startup

data TrackingStationOpts = TrackingStationOpts {
    tsUpdate :: Defaultable Bool
  , tsTrackers :: Defaultable [String]
  , tsSats :: Defaultable [String]
} deriving (Eq, Show, Ord, Generic, Typeable)

instance Binary TrackingStationOpts
instance Hashable TrackingStationOpts

tsSchema :: Opt.Parser TrackingStationOpts
tsSchema = let
    upd = defaultable False . Opt.switch
             $ Opt.long "update"
            <> Opt.short 'u'
            <> Opt.help "Update something."
    trackers = defaultable [] . Opt.many . Opt.strOption
             $ Opt.long "trackers"
            <> Opt.short 't'
            <> Opt.help "Addresses to spawn tracking station nodes on."
            <> Opt.metavar "ADDRESSES"
    sats =  defaultable [] . Opt.many . Opt.strOption
             $ Opt.long "satellites"
            <> Opt.short 's'
            <> Opt.help "Satellite node addresses (not including trackers)."
            <> Opt.metavar "ADDRESSES"
  in TrackingStationOpts <$> upd
                         <*> trackers
                         <*> sats

self :: String
self = "HA.TrackingStation"

startTS :: NodeId -> TrackingStationOpts -> Process ()
startTS nid naConf = void . spawnLocal $ do
    say $ "This is " ++ self
    result <- call $(functionTDict 'ignition) nid $
               $(mkClosure 'ignition) args
    case result of
      Just (added, trackers, mpids, members, newNodes) -> liftIO $ do
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
        mapM_ print $ [ tracker | (Nothing, tracker) <- zip mpids trackers ]
      Nothing -> return ()
  where
    args = ( fromDefault . tsUpdate $ naConf
           , fromDefault . tsTrackers $ naConf
           , fromDefault . tsSats $ naConf
           )
