{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
-- |
-- Module    : Handler.Mero.Helpers
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Helper module with utility functions used by various commands.
module Handler.Mero.Helpers
  ( clusterCommand
  , fidOpt
  , runJob
  , waitJob
  ) where

import           Control.Distributed.Process hiding (die)
import           Control.Distributed.Process.Serializable
import           Control.Monad
import           Data.Typeable
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events
import           HA.RecoveryCoordinator.RC.Subscription
import           HA.SafeCopy
import           Mero.ConfC (Fid, strToFid)
import           Network.CEP (Published(..))
import qualified Options.Applicative as Opt
import           System.Exit (die)

clusterCommand :: (SafeCopy a, Serializable a, Serializable b, Show b)
               => [NodeId]
               -> Maybe Int -- ^ Custom timeout in seconds, default 10s
               -> (SendPort b -> a)
               -> (b -> Process c)
               -> Process c
clusterCommand eqnids mt mk f = do
  (sp, rp) <- newChan
  promulgateEQ eqnids (mk sp) >>= flip withMonitor wait
  let t = maybe 10000000 (* 1000000) mt
  receiveTimeout t [matchChan rp f] >>= liftIO . \case
    Nothing -> die "Timed out waiting for cluster status reply from RC."
    Just c -> return c
  where
    wait = void (expect :: Process ProcessMonitorNotification)

-- | Parser for 'Fid' type
fidOpt :: Opt.Mod Opt.OptionFields Fid -> Opt.Parser Fid
fidOpt = Opt.option (Opt.maybeReader strToFid)

-- | Run a job. If an action is given, run synchronously waiting for
-- the result and run the action on it.
runJob :: forall a b. (SafeCopy a, Typeable a, Serializable b, Show b)
       => [NodeId] -- ^ EQ
       -> a -- ^ Job start message
       -> Maybe (b -> Process ())
       -> Process ()
runJob nids msg mact = do
  waitResult <- waitJob nids mact
  l <- startJobEQ nids msg
  waitResult l

-- | Wait for a potential job result. It's close to 'runJob' but
-- someone else starts a job. Once we obtain 'ListenerId', we provide
-- it to the resulting deferred computation to actually wait and act
-- on the result.
waitJob :: forall a. (Serializable a, Show a)
        => [NodeId] -- ^ EQ
        -> Maybe (a -> Process ())
        -> Process (ListenerId -> Process ())
waitJob _ Nothing = return $ \_ -> return ()
waitJob nids (Just act) = do
  let result = Proxy :: Proxy (JobFinished a)
  subscribeOnTo nids result
  return $ \l -> do
    v <- receiveWait
      [ matchIf (\(Published (JobFinished lis _) _) -> l `elem` lis)
                (\(Published (JobFinished _ v) _) -> return v) ]
    act v
    unsubscribeOnFrom nids result
