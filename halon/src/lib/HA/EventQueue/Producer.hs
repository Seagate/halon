-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This is the Event Producer API, used by services.

{-# LANGUAGE LambdaCase #-}
module HA.EventQueue.Producer
  ( promulgateEQ
  , promulgateEQ_
  , promulgateEQPref
  , promulgate
  , promulgateWait
  , promulgateEvent
  ) where

import           HA.CallTimeout (ncallRemoteSome, ncallRemoteSomePrefer)
import qualified HA.EQTracker.Internal as EQT
import           HA.EventQueue.Types
import           HA.Logger
import           HA.SafeCopy

import           Control.Distributed.Process hiding (bracket)
import           Control.Monad (when, void)
import           Control.Monad.Catch (bracket)

import           Data.Maybe (maybeToList)
import           Data.List ((\\))
import           Data.Typeable

producerTrace :: String -> Process ()
producerTrace = mkHalonTracer "EQ.producer"

data Result = Success | Failure
  deriving (Eq, Show)

softTimeout :: Int
softTimeout = 5000000

-- This timeout needs to be higher than the staggering
-- hard timeout.
promulgateTimeout :: Int
promulgateTimeout = 5000000

-- | Promulgate an event directly to an EQ node without indirection
--   via the "HA.EQTracker".
promulgateEQ :: (SafeCopy a, Typeable a)
             => [NodeId] -- ^ EQ nodes.
             -> a -- ^ Event to send.
             -> Process ProcessId -- ^ PID of the spawned process. This can
                                  --   be used to verify receipt.
promulgateEQ eqnids x = spawnLocal $ do
    msg <- newPersistMessage x
    producerTrace $ "promulgateEQ: " ++ show (typeOf x, persistMessageId msg)
    go msg
  where
    go evt = do
      res <- promulgateHAEvent eqnids evt
      when (res == Failure) $ receiveTimeout 1000000 [] >> go evt

-- | Like 'promulgateEQ', but ignores the result.
promulgateEQ_ :: (SafeCopy a, Typeable a) => [NodeId] -> a -> Process ()
promulgateEQ_ nids = void . promulgateEQ nids

-- | Like 'promulgateEQ', but express a preference for certain EQ nodes.
promulgateEQPref :: (SafeCopy a, Typeable a)
                 => [NodeId] -- ^ Preferred EQ nodes.
                 -> [NodeId] -- ^ All EQ nodes.
                 -> a -- ^ Event to send.
                 -> Process ProcessId
promulgateEQPref peqnids eqnids x = spawnLocal $ do
    m <- newPersistMessage x
    producerTrace $ "promulgateEQPref: " ++ show (typeOf x, persistMessageId m)
    go m
  where
    go evt = do
      res <- promulgateHAEventPref peqnids eqnids evt
      when (res == Failure) $ receiveTimeout 1000000 [] >> go evt

-- | Add an event to the event queue, and don't die yet. This uses the local
--   event tracker to identify the list of EQ nodes.
-- FIXME: Use a well-defined timeout.
promulgate :: (SafeCopy a, Typeable a) => a -> Process ProcessId
promulgate x = do
    m <- newPersistMessage x
    producerTrace $ "promulgate: " ++ show (typeOf x, persistMessageId m)
    promulgateEvent m

-- | Send message and wait until it will be acknowledged, this method is
-- blocking. Main difference with non-blocking promulgate function is that
-- 'promulgateWait' will cancel promulgate call in case if caller thread
-- will receive an exception, if this is not desired behaviour - use
-- 'promulgate' instead.
promulgateWait :: (SafeCopy a, Typeable a) => a -> Process ()
promulgateWait x =
   bracket (promulgate x)
           (flip kill "caller was killed")
           $ \sender -> do
     mref <- monitor sender
     receiveWait [matchIf (\(ProcessMonitorNotification p _ _) -> p == mref)
                          (const $ return ())
                 ]

-- | Add an event to the event queue. This form takes the HAEvent directly.
promulgateEvent :: PersistMessage -> Process ProcessId
promulgateEvent evt =
    spawnLocal go
  where
    go = do
      self <- getSelfPid
      nsend EQT.name $ EQT.ReplicaRequest self
      rl <- expectTimeout softTimeout
      case rl of
        Just (EQT.ReplicaReply (EQT.ReplicaLocation _ [])) ->
          void (receiveTimeout 1000000 []) >> go
        Just (EQT.ReplicaReply (EQT.ReplicaLocation Nothing rest)) -> do
          res <- promulgateHAEvent rest evt
          producerTrace $ "promulgateEvent: " ++ show (res, persistMessageId evt)
          when (res == Failure) $ receiveTimeout 1000000 [] >> go
        Just (EQT.ReplicaReply (EQT.ReplicaLocation pref rest)) -> do
          res <- promulgateHAEventPref (maybeToList pref) rest evt
          producerTrace $ "promulgateEvent: " ++ show (res, persistMessageId evt)
          when (res == Failure) $ receiveTimeout 1000000 [] >> go
        Nothing -> receiveTimeout 1000000 [] >> go

-- | Promulgate an HAEvent directly to EQ nodes. We also try to inform the
--   local EQ tracker about preferred replicas, if available.
promulgateHAEvent :: [NodeId] -- ^ EQ nodes.
                  -> PersistMessage
                  -> Process Result
promulgateHAEvent eqnids msg = do
  producerTrace $ "Sending " ++ show (persistMessageId msg) ++ " to " ++ show eqnids
  result <- callLocal $
    ncallRemoteSome promulgateTimeout eqnids eventQueueLabel msg snd
  producerTrace $ "promulgateHAEvent: " ++ show (result, persistMessageId msg)
  case result of
    (rnid, True) : _ -> do
      nsend EQT.name $ EQT.PreferReplica rnid
      return Success
    _ -> return Failure

-- | Promulgate an HAEvent directly to EQ nodes, specifying a preference for
--   certain nodes first. We also try to inform the local EQ tracker about
--   preferred replicas, if available.
promulgateHAEventPref :: [NodeId] -- ^ Preferred EQ nodes.
                      -> [NodeId] -- ^ All EQ nodes.
                      -> PersistMessage
                      -> Process Result
promulgateHAEventPref peqnids eqnids msg = do
  producerTrace $ "Sending " ++ show (persistMessageId msg)
                   ++ " to " ++ show peqnids
                   ++ " and then to " ++ show (eqnids \\ peqnids)
  result <- callLocal $ ncallRemoteSomePrefer
      softTimeout promulgateTimeout
      peqnids (eqnids \\ peqnids)
      eventQueueLabel msg
      snd
  producerTrace $ "promulgateHAEventPref: " ++ show (result, persistMessageId msg)
  case result of
    (rnid, True) : _ -> do
      nsend EQT.name $ EQT.PreferReplica rnid
      return Success
    _ -> return Failure
