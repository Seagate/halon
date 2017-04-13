{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : Handler.Mero.Helpers
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Helper module with utility functions used by various commands.
module Handler.Mero.Helpers
  ( clusterCommand
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad
import           HA.EventQueue (promulgateEQ)
import           HA.SafeCopy
import           System.Exit (exitFailure)
import           System.IO (hPutStrLn, stderr)

clusterCommand :: (SafeCopy a, Serializable a, Serializable b, Show b)
               => [NodeId]
               -> Maybe Int -- ^ Custom timeout in seconds, default 10s
               -> (SendPort b -> a)
               -> (b -> Process c)
               -> Process c
clusterCommand eqnids mt mk f = do
  (schan, rchan) <- newChan
  promulgateEQ eqnids (mk schan) >>= flip withMonitor wait
  let t = maybe 10000000 (* 1000000) mt
  receiveTimeout t [ matchChan rchan f ] >>= liftIO . \case
    Nothing -> do
      hPutStrLn stderr "Timed out waiting for cluster status reply from RC."
      exitFailure
    Just c -> return c
  where
    wait = void (expect :: Process ProcessMonitorNotification)
