{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Implementation of the EQ Tracker process.
-- For user facing documentation, please refer to "HA.EQTracker".
module HA.EQTracker.Process
  ( -- * Public API.
    startEQTracker
    -- ** Update
  , updateEQNodes
  , name
    -- ** Lookup
  , lookupReplicas
  , ReplicaReply(..)
  , ReplicaLocation(..)
    -- * D-P internals.
  , updateEQNodes__static
  , updateEQNodes__sdict
  , updateEQNodes__tdict
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Monad (unless)
import Data.List (union)
import HA.Debug
import HA.EQTracker.Internal
import HA.Logger (mkHalonTracer)

-- | Internal logs.
traceTracker :: String -> Process ()
traceTracker = mkHalonTracer "EQTracker"

-- | Updates EQ tracker of the node. First it waits until the EQ tracker
-- is registered and then it sends the request to update the list of
-- EQ nodes.
updateEQNodes :: [NodeId] -- ^ List of new event queue nodes.
              -> Process ()
updateEQNodes ns = do
  mt <- whereis name
  case mt of
    Nothing -> receiveTimeout 100000 [] >> updateEQNodes ns
    Just pid -> do
      self <- getSelfPid
      usend pid $ UpdateEQNodes self ns
      result <- expectTimeout 1000000
      unless (result == Just UpdateEQNodesAck) $ updateEQNodes ns

remotable [ 'updateEQNodes ]

-- | Run Event Queue process.
--
-- This process is not intended to fail, in because if this process
-- fails then there is no way to reliably send messages to the EQ.
eqTrackerProcess :: [NodeId] -> Process ()
eqTrackerProcess nodes = go $ ReplicaLocation Nothing nodes
    where
      go eqs = do
        receiveWait
          [ match $ \(UpdateEQNodes caller eqnids) -> do
              say $ "Got UpdateEQNodes: " ++ show eqnids
              usend caller UpdateEQNodesAck
              let !preferred = do r <- eqsPreferredReplica eqs
                                  if elem r eqnids then return r
                                    else Nothing
              return $ eqs
                { eqsReplicas = eqnids
                  -- Preserve the preferred replica only if it belongs
                  -- to the new list of nodes.
                , eqsPreferredReplica = preferred
                }
          , match $ \prs@(PreferReplica rnid) -> do
              traceTracker $ "Got " ++ show prs
              if eqsPreferredReplica eqs == Just rnid
              then return eqs
              else return $ handleEQResponse eqs rnid
          , match $ \(ReplicaRequest requester) -> do
              usend requester $ ReplicaReply eqs
              return eqs
          ] >>= go

-- | The EQ response may suggest to contact another replica. This function
-- handles the EQTracker state update.
--
-- @handleEQResponse naState responsiveNid@
--
handleEQResponse :: ReplicaLocation -> NodeId -> ReplicaLocation
handleEQResponse eqs rnid =
    eqs { eqsPreferredReplica = Just rnid
        , eqsReplicas = [rnid] `union` eqsReplicas eqs
        }

-- | Spawn 'eqTrackerProcess' with the given replicas.
startEQTracker :: [NodeId] -> Process ProcessId
startEQTracker eqs = do
    eqt <- spawnLocalName "ha::eq" $ eqTrackerProcess eqs
    register name eqt
    return eqt

-- | Lookup replica from the given node. After sending this request
-- Process will receive 'ReplicaReply' in its mailbox.
lookupReplicas :: NodeId -> Process ()
lookupReplicas n = do
  self <- getSelfPid
  nsendRemote n name $ ReplicaRequest self
