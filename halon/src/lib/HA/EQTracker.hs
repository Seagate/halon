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
  , eqTrackerProcess
  , name
  , HA.EQTracker.__remoteTableDecl
  ) where

import HA.NodeAgent.Messages (ServiceMessage(UpdateEQNodes))

import Control.SpineSeq (spineSeq)
import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Closure

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (intersect, sort)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)
import Text.Printf

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


remotableDecl [ [d|

  -- | Run Event Queue process.
  --
  -- This process is not intended to fail, in because if this process
  -- fails then there is no way to reliably send messages to the EQ.
  eqTrackerProcess :: [NodeId] -> Process ()
  eqTrackerProcess nodes = do
      self <- getSelfPid
      ensureRegistered self
      go $ ReplicaLocation [] nodes
    where
      ensureRegistered pid = do
        exists <- whereis name
        case exists of
          Just old -> do
            -- XXX: announce the change, ideally we should register ourself on RC
            say $ printf "EQTracker: reregistering %s (old EQT was %s)" name (show old)
            reregister name pid
          Nothing -> register name pid
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
      in eqs{ eqsPreferredReplicas = preferred }
    else
      eqs

  |] ]