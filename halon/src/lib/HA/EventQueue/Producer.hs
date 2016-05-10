-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is the Event Producer API, used by services.

{-# LANGUAGE LambdaCase #-}
module HA.EventQueue.Producer
  ( promulgateEQ
  , promulgateEQPref
  , promulgate
  , promulgateWait
  , promulgateEvent
  , expiate
  ) where

import HA.CallTimeout
  ( ncallRemoteSome
  , ncallRemoteSomePrefer
  )
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types
import HA.Logger
import qualified HA.EQTracker as EQT

import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad (when, void)

import Data.Maybe (maybeToList)
import Data.List ((\\))
import Data.Typeable

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
--   via the NodeAgent. Note that this spawns a local process in order
--   to ensure that the event id is unique.
promulgateEQ :: Serializable a
             => [NodeId] -- ^ EQ nodes.
             -> a -- ^ Event to send.
             -> Process ProcessId -- ^ PID of the spawned process. This can
                                  --   be used to verify receipt.
promulgateEQ eqnids x = spawnLocal $ do
    m <- newPersistMessage x
    producerTrace $ "promulgateEQ: " ++ show (typeOf x, persistEventId m)
    go m
  where
    go evt = do
      res <- promulgateHAEvent eqnids evt
      when (res == Failure) $ receiveTimeout 1000000 [] >> go evt

-- | Like 'promulgateEQ', but express a preference for certain EQ nodes.
promulgateEQPref :: Serializable a
                 => [NodeId] -- ^ Preferred EQ nodes.
                 -> [NodeId] -- ^ All EQ nodes.
                 -> a -- ^ Event to send.
                 -> Process ProcessId
promulgateEQPref peqnids eqnids x = spawnLocal $ do
    m <- newPersistMessage x
    producerTrace $ "promulgateEQPref: " ++ show (typeOf x, persistEventId m)
    go m
  where
    go evt = do
      res <- promulgateHAEventPref peqnids eqnids evt
      when (res == Failure) $ receiveTimeout 1000000 [] >> go evt

-- | Add an event to the event queue, and don't die yet. This uses the local
--   event tracker to identify the list of EQ nodes.
-- FIXME: Use a well-defined timeout.
promulgate :: Serializable a => a -> Process ProcessId
promulgate x = do
    m <- newPersistMessage x
    producerTrace $ "promulgate: " ++ show (typeOf x, persistEventId m)
    promulgateEvent m

-- | Send message and wait until it will be acknowledged, this method is
-- blocking. Main difference with non-blocking promulgate function is that
-- 'promulgateWait' will cancel promulgate call in case if caller thread
-- will receive an exception, if this is not desired behaviour - use
-- 'promulgate' instead.
promulgateWait :: Serializable a => a -> Process ()
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
          producerTrace $ "promulgateEvent: " ++ show (res, persistEventId evt)
          when (res == Failure) $ receiveTimeout 1000000 [] >> go
        Just (EQT.ReplicaReply (EQT.ReplicaLocation pref rest)) -> do
          res <- promulgateHAEventPref (maybeToList pref) rest evt
          producerTrace $ "promulgateEvent: " ++ show (res, persistEventId evt)
          when (res == Failure) $ receiveTimeout 1000000 [] >> go
        Nothing -> receiveTimeout 1000000 [] >> go

-- | Promulgate an HAEvent directly to EQ nodes. We also try to inform the
--   local EQ tracker about preferred replicas, if available.
promulgateHAEvent :: [NodeId] -- ^ EQ nodes.
                  -> PersistMessage
                  -> Process Result
promulgateHAEvent eqnids msg = do
  producerTrace $ "Sending " ++ show (persistEventId msg) ++ " to " ++ show eqnids
  result <- callLocal $
    ncallRemoteSome promulgateTimeout eqnids eventQueueLabel msg snd
  producerTrace $ "promulgateHAEvent: " ++ show (result, persistEventId msg)
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
  producerTrace $ "Sending " ++ show (persistEventId msg)
                   ++ " to " ++ show peqnids
                   ++ " and then to " ++ show (eqnids \\ peqnids)
  result <- callLocal $ ncallRemoteSomePrefer
      softTimeout promulgateTimeout
      peqnids (eqnids \\ peqnids)
      eventQueueLabel msg
      snd
  producerTrace $ "promulgateHAEventPref: " ++ show (result, persistEventId msg)
  case result of
    (rnid, True) : _ -> do
      nsend EQT.name $ EQT.PreferReplica rnid
      return Success
    _ -> return Failure

-- | Add a new event to the event queue and then die.
expiate :: Serializable a => a -> Process ()
expiate x = promulgate x >> die "Expiate."
