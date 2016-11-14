{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.
--
-- EventQueueTracker intended to to track the location of (a subset of) EventQueue
-- nodes. This simplifies expediting messages to the Recovery Co-ordinator, since each
-- individual service need not track the location of the EventQueue nodes.
--
-- Note that the EQTracker does not act as a proxy for the EventQueue, it just
-- serves as a registry.
module HA.EQTracker
  ( ReplicaLocation(..)
  , ReplicaRequest(..)
  , ReplicaReply(..)
  , PreferReplica(..)
  , UpdateEQNodes(..)
  , UpdateEQNodesAck(..)
  , startEQTracker
  , name
  , updateEQNodes
  , updateEQNodes__static
  , updateEQNodes__sdict
  , updateEQNodes__tdict
  , __remoteTable
  ) where

import HA.Debug
import HA.Logger (mkHalonTracer)
import Control.Distributed.Process
import Control.Distributed.Process.Closure

import Control.Monad (unless)
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (union)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

-- | Update the nids of the EQs, for example, in the event of the
-- RC restarting on a different node.
--
-- @'UpdateEQNodes' caller eqnodes@
data UpdateEQNodes = UpdateEQNodes ProcessId [NodeId]
  deriving (Eq, Show, Generic, Typeable)
instance Binary UpdateEQNodes

-- | Reply to 'UpdateEQNodes', sent to the caller.
data UpdateEQNodesAck = UpdateEQNodesAck
  deriving (Eq, Show, Generic, Typeable)
instance Binary UpdateEQNodesAck

-- | Loop state for the tracker. We store a preferred replica as well as the
-- full list of known replicas. None of these are guaranteed to exist.
data ReplicaLocation = ReplicaLocation
  { eqsPreferredReplica :: Maybe NodeId
  , eqsReplicas :: [NodeId]
  } deriving (Eq, Generic, Show, Typeable)

instance Binary ReplicaLocation
instance Hashable ReplicaLocation

-- | Message sent by clients to indicate a preference for a certain replica.
data PreferReplica = PreferReplica NodeId
  deriving (Eq, Generic, Show, Typeable)

instance Binary PreferReplica
instance Hashable PreferReplica

-- | Message sent by clients to request a replica list.
newtype ReplicaRequest = ReplicaRequest ProcessId
  deriving (Eq, Show, Typeable, Binary, Hashable)

newtype ReplicaReply = ReplicaReply ReplicaLocation
  deriving (Eq, Show, Typeable, Binary, Hashable)

-- | Process label: @"HA.EQTracker"@
name :: String
name = "HA.EQTracker"

traceTracker :: String -> Process ()
traceTracker = mkHalonTracer "EQTracker"

-- | Updates EQ tracker of the node. First it waits until the EQ tracker
-- is registered and then it sends the request to update the list of
-- EQ nodes
updateEQNodes :: [NodeId] -> Process ()
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
              traceTracker $ "Got PreferReplicas: " ++ show prs
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
