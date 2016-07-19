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

import HA.EventQueue.Producer (promulgateEQ)
import HA.RecoveryCoordinator.Events.Debug
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
    self <- getSelfPid
    eqs <- findEQFromNodes t nids
    resp <- mapM (go self eqs) nids
    let stats = zip nids resp
    mapM_ (liftIO . putStrLn . display) stats
  where
    go self eqs nid = do
        promulgateEQ eqs msg >>= \pid -> withMonitor pid wait
      where
        msg = NodeStatusRequest (Node nid) [self]
        wait = do
          _ <- expect :: Process ProcessMonitorNotification
          expectTimeout t
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
