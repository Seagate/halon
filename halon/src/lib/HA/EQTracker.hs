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

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.EQTracker
  ( ReplicaLocation(..)
  , ReplicaRequest(..)
  , ReplicaReply(..)
  , PreferReplicas(..)
  , ServiceMessage(..)
  , startEQTracker
  , name
  , updateEQNodes
  , updateEQNodes__static
  , updateEQNodes__sdict
  , __remoteTable
  ) where

import Control.SpineSeq (spineSeq)
import Control.Distributed.Process
import Control.Distributed.Process.Closure

import Control.Monad (unless)
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (intersect, sort, union)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

data ServiceMessage =
    -- | Update the nids of the EQs, for example, in the event of the
    -- RC restarting on a different node.
    UpdateEQNodes [NodeId]
  deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceMessage

-- | Loop state for the tracker. We store a list of preferred replicas as
--   well as the full list of known replicas. None of these are guaranteed
--   to exist.
data ReplicaLocation = ReplicaLocation
  { eqsPreferredReplicas :: [NodeId]
  , eqsReplicas :: [NodeId]
  } deriving (Eq, Generic, Show, Typeable)

instance Binary ReplicaLocation
instance Hashable ReplicaLocation

-- | Message sent by clients to indicate a preference for certain replicas.
data PreferReplicas = PreferReplicas
  { responsiveNid :: NodeId
  , preferredNid :: NodeId
  }
  deriving (Eq, Generic, Show, Typeable)

instance Binary PreferReplicas
instance Hashable PreferReplicas

-- | Message sent by clients to request a replica list.
newtype ReplicaRequest = ReplicaRequest ProcessId
  deriving (Eq, Show, Typeable, Binary, Hashable)

newtype ReplicaReply = ReplicaReply ReplicaLocation
  deriving (Eq, Show, Typeable, Binary, Hashable)

name :: String
name = "HA.EQTracker"

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
      usend pid (self, UpdateEQNodes ns)
      result <- expectTimeout 1000000
      unless (result == Just True) $ updateEQNodes ns

remotable [ 'updateEQNodes ]

-- | Run Event Queue process.
--
-- This process is not intended to fail, in because if this process
-- fails then there is no way to reliably send messages to the EQ.
eqTrackerProcess :: [NodeId] -> Process ()
eqTrackerProcess nodes = do
      go $ ReplicaLocation [] nodes
    where
      go eqs = do
        receiveWait
          [ match $ \(caller, UpdateEQNodes eqnids) -> do
              say $ "Got UpdateEQNodes: " ++ show eqnids
              usend caller True
              let !preferred = spineSeq $ intersect eqnids (eqsPreferredReplicas eqs)
              return $ eqs
                { eqsReplicas = eqnids
                  -- Preserve the preferred replica only if it belongs
                  -- to the new list of nodes.
                , eqsPreferredReplicas = preferred
                }
          , match $ \prs@(PreferReplicas rnid pnid) -> do
              say $ "Got PreferReplicas: " ++ show prs
              return $ handleEQResponse eqs rnid pnid
          , match $ \(ReplicaRequest requester) -> do
              usend requester $ ReplicaReply eqs
              return eqs
          ] >>= go

-- The EQ response may suggest to contact another replica. This function
-- handles the EQTracker state update.
--
-- @handleEQResponse naState responsiveNid preferredNid@
--
handleEQResponse :: ReplicaLocation -> NodeId -> NodeId -> ReplicaLocation
handleEQResponse eqs rnid pnid =
    if sort [rnid, pnid] /= sort (eqsPreferredReplicas eqs)
    then
      let !preferred = if rnid == pnid
                       then [rnid] -- The EQ sugested itself.
                       else if rnid `elem` (eqsPreferredReplicas eqs)
                            then [pnid] -- Likely we have not tried reaching the preferred node yet.
                            else [rnid, pnid] -- The preferred replica did not respond soon enough.
      in eqs{ eqsPreferredReplicas = preferred
            , eqsReplicas = preferred `union` eqsReplicas eqs
            }
    else
      eqs

startEQTracker :: [NodeId] -> Process ProcessId
startEQTracker eqs = do
    eqt <- spawnLocal $ eqTrackerProcess eqs
    register name eqt
    return eqt
