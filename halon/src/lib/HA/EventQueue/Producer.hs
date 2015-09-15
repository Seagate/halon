-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is the Event Producer API, used by services.

module HA.EventQueue.Producer
  ( promulgateEQ
  , promulgateEQPref
  , promulgate
  , promulgateEvent
  , expiate
  ) where

import HA.CallTimeout
  ( ncallRemoteAnyTimeout
  , ncallRemoteAnyPreferTimeout
  )
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types
import qualified HA.EQTracker as EQT

import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad (when, void)

import Data.List ((\\))
import Data.Typeable

producerTrace :: String -> Process ()
producerTrace _ = return ()
-- producerTrace = say . ("[EQ.producer] " ++)

data Result = Success | Failure
  deriving Eq

softTimeout :: Int
softTimeout = 5000000

-- This timeout needs to be higher than the staggering
-- hard timeout.
promulgateTimeout :: Int
promulgateTimeout = 15000000

-- | Promulgate an event directly to an EQ node without indirection
--   via the NodeAgent. Note that this spawns a local process in order
--   to ensure that the event id is unique.
promulgateEQ :: Serializable a
             => [NodeId] -- ^ EQ nodes.
             -> a -- ^ Event to send.
             -> Process ProcessId -- ^ PID of the spawned process. This can
                                  --   be used to verify receipt.
promulgateEQ eqnids x = spawnLocal $ do
    newPersistMessage x >>= go
  where
    go evt = do
      res <- promulgateHAEvent eqnids evt
      when (res == Failure) $ go evt

-- | Like 'promulgateEQ', but express a preference for certain EQ nodes.
promulgateEQPref :: Serializable a
                 => [NodeId] -- ^ Preferred EQ nodes.
                 -> [NodeId] -- ^ All EQ nodes.
                 -> a -- ^ Event to send.
                 -> Process ProcessId
promulgateEQPref peqnids eqnids x = spawnLocal $ do
    newPersistMessage x >>= go
  where
    go evt = do
      res <- promulgateHAEventPref peqnids eqnids evt
      when (res == Failure) $ go evt

-- | Add an event to the event queue, and don't die yet. This uses the local
--   event tracker to identify the list of EQ nodes.
-- FIXME: Use a well-defined timeout.
promulgate :: Serializable a => a -> Process ProcessId
promulgate x = do
    m <- newPersistMessage x
    producerTrace $ "Promulgating: " ++ show (typeOf x, persistEventId m)
    promulgateEvent m

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
        Just (EQT.ReplicaReply (EQT.ReplicaLocation [] rest)) -> do
          res <- promulgateHAEvent rest evt
          when (res == Failure) go
        Just (EQT.ReplicaReply (EQT.ReplicaLocation pref rest)) -> do
          res <- promulgateHAEventPref pref rest evt
          when (res == Failure) go
        Nothing -> go

-- | Promulgate an HAEvent directly to EQ nodes. We also try to inform the
--   local EQ tracker about preferred replicas, if available.
promulgateHAEvent :: [NodeId] -- ^ EQ nodes.
                  -> PersistMessage
                  -> Process Result
promulgateHAEvent eqnids msg = do
  say $ "Sending to " ++ (show eqnids)
  result <- callLocal $
    ncallRemoteAnyTimeout
      promulgateTimeout eqnids eventQueueLabel msg
  case result :: Maybe (NodeId, NodeId) of
    Nothing -> return Failure
    Just (rnid, pnid) -> do
      nsend EQT.name $ EQT.PreferReplicas rnid pnid
      return Success

-- | Promulgate an HAEvent directly to EQ nodes, specifying a preference for
--   certain nodes first. We also try to inform the local EQ tracker about
--   preferred replicas, if available.
promulgateHAEventPref :: [NodeId] -- ^ Preferred EQ nodes.
                      -> [NodeId] -- ^ All EQ nodes.
                      -> PersistMessage
                      -> Process Result
promulgateHAEventPref peqnids eqnids msg = do
  say $ "Sending to " ++ (show peqnids) ++ " and then to " ++ show (eqnids \\ peqnids)
  result <- callLocal $
    ncallRemoteAnyPreferTimeout
      softTimeout promulgateTimeout
      peqnids (eqnids \\ peqnids)
      eventQueueLabel msg
  case result :: Maybe (NodeId, NodeId) of
    Nothing -> return Failure
    Just (rnid, pnid) -> do
      nsend EQT.name $ EQT.PreferReplicas rnid pnid
      return Success

-- | Add a new event to the event queue and then die.
expiate :: Serializable a => a -> Process ()
expiate x = promulgate x >> die "Expiate."
