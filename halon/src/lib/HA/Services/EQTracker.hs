-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.
--
-- Service to track the location of (a subset of) EventQueue nodes. This
-- simplifies expediting messages to the Recovery Co-ordinator, since each
-- individual service need not track the location of the EventQueue nodes.
--
-- Note that the EQTracker does not act as a proxy for the EventQueue, it just
-- serves as a registry.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.EQTracker
  ( ReplicaLocation(..)
  , ReplicaRequest(..)
  , ReplicaReply(..)
  , PreferReplicas(..)
  , eqTracker
  , name
  , HA.Services.EQTracker.__remoteTableDecl
  ) where

import HA.NodeAgent.Messages (ServiceMessage(UpdateEQNodes))
import HA.Service
import HA.Services.Empty

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (intersect)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

-- | Loop state for the tracker. We store a list of preferred replicas as
--   well as the full list of known replicas. None of these are guaranteed
--   to exist.
data ReplicaLocation = ReplicaLocation
  { eqsPreferredReplicas :: [NodeId]
  , eqsReplicas :: [NodeId]
  } deriving (Eq, Generic, Show)

instance Binary ReplicaLocation
instance Hashable ReplicaLocation

-- | Message sent by clients to indicate a preference for certain replicas.
newtype PreferReplicas = PreferReplicas [NodeId]
  deriving (Eq, Show, Typeable, Binary, Hashable)

-- | Message sent by clients to request a replica list.
newtype ReplicaRequest = ReplicaRequest ProcessId
  deriving (Eq, Show, Typeable, Binary, Hashable)

newtype ReplicaReply = ReplicaReply ReplicaLocation
  deriving (Eq, Show, Typeable, Binary, Hashable)

name :: String
name = "HA.EQTracker"

remotableDecl [ [d|

  eqTrackerProcess :: () -> Process ()
  eqTrackerProcess _ = do
      self <- getSelfPid
      ensureRegistered self
      go $ ReplicaLocation [] []
    where
      ensureRegistered pid = do
        exists <- whereis name
        case exists of
          Just _ -> reregister name pid
          Nothing -> register name pid
      go eqs = do
        receiveWait
          [ match $ \(caller, UpdateEQNodes eqnids) -> do
              say $ "Got UpdateEQNodes: " ++ show eqnids
              send caller True
              return $ eqs
                { eqsReplicas = eqnids
                  -- Preserve the preferred replica only if it belongs
                  -- to the new list of nodes.
                , eqsPreferredReplicas = intersect
                                          (eqsPreferredReplicas eqs)
                                          eqnids
                }
          , match $ \(PreferReplicas prs) -> do
              say $ "Got PreferReplicas: " ++ show prs
              return $ eqs
                { eqsPreferredReplicas = intersect
                                          (eqsReplicas eqs)
                                          prs
                }
          , match $ \(ReplicaRequest requester) -> do
              send requester $ ReplicaReply eqs
              return eqs
          ] >>= go

  eqTracker :: Service ()
  eqTracker = Service
                (ServiceName name)
                ($(mkStaticClosure 'eqTrackerProcess))
                ($(mkStatic 'someConfigDict)
                  `staticApply` $(mkStatic 'emptyConfigDict))

  |] ]
