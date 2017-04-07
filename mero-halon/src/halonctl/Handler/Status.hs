{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Querying status of nodes.

module Handler.Status
  ( StatusOptions
  , parseStatus
  , status
  ) where

import HA.EventQueue
import HA.RecoveryCoordinator.RC.Events.Info
import HA.Resources

import Lookup

import Control.Distributed.Process
import Control.Monad (join)

import Data.Monoid ((<>))

import qualified Options.Applicative as O

data StatusOptions = StatusOptions
    Int
  deriving (Eq, Show)

parseStatus :: O.Parser StatusOptions
parseStatus = StatusOptions
  <$> O.option O.auto (
        O.metavar "TIMEOUT (μs)"
        <> O.long "eqt-timeout"
        <> O.value 1000000
        <> O.help ("Time to wait from a reply from the EQT when" ++
                  " querying the location of an EQ.")
      )

status :: [NodeId] -> StatusOptions -> Process ()
status nids (StatusOptions t) = do
    eqs <- findEQFromNodes t nids
    stats <- mapM (go eqs) nids
    mapM_ (liftIO . putStrLn . display) stats
  where
    go eqs nid = do
        (sp, rp) <- newChan
        let msg = NodeStatusRequest (Node nid) sp
        promulgateEQ eqs msg >>= \pid -> withMonitor pid (wait rp)
      where
        wait rp = do
          _ <- expect :: Process ProcessMonitorNotification
          (,) <$> pure nid <*> receiveChanTimeout t rp

    display (nid, Nothing) = show nid ++ ": No reply from RC."
    display (nid, Just (NodeStatusResponse{..})) = join $
        [ show nid ++ ":"
        , "\n\t" ++ ts
        , "\n\t" ++ sat
        ]
      where
        ts = if nsrIsStation
              then "is a tracking station node."
              else "is not a tracking station node."
        sat = if nsrIsSatellite
              then "is a satellite node."
              else "is not a satellite node."
