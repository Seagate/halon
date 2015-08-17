-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Logic for reporting a new Node has been added to the cluster. A NodeUp
-- process is spawned which is responsible for sending `NodeUp` messages
-- to the RC until it acknowledges, at which point the process dies.

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.NodeUp
  ( NodeUp(..)
  , nodeUp
  , nodeUp__static
  , nodeUp__sdict
  , __remoteTable
  )
where

import HA.EventQueue.Producer (promulgate)
import qualified HA.EQTracker as EQT
import HA.NodeAgent.Messages (ServiceMessage(..))

import Control.Distributed.Process
  ( NodeId
  , ProcessId
  , Process
  , getSelfPid
  , nsend
  , expect
  , say
  , processNodeId
  , monitor
  , kill
  , ProcessMonitorNotification(..)
  , receiveTimeout
  , matchIf
  )
import Control.Distributed.Process.Closure ( remotable )
import Control.Monad.Trans (liftIO)

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.HostName

-- | NodeUp message sent to the RC (via EQ) when a node starts.
data NodeUp = NodeUp
              String -- ^ Node hostname
              ProcessId
  deriving (Eq, Show, Typeable, Generic)

instance Binary NodeUp
instance Hashable NodeUp

-- | Process which setup EQT and then repeatedly sends 'NodeUp' messages
--   to the EQ, until one is acknowledged with a '()' reply.
nodeUp :: ( [NodeId] -- ^ Set of EQ nodes to contact
          , Int -- ^ Interval between sending messages (ms)
          )
       -> Process ()
nodeUp (eqs, delay) = do
    self <- getSelfPid
    nsend EQT.name (self, UpdateEQNodes eqs)
    go self
  where
    go pid = do
      say $ "Sending NodeUp message to " ++ show eqs ++ " me -> " ++ (show $ processNodeId pid)
      h <- liftIO $ getHostName
      sender <- promulgate $ NodeUp h pid
      ref <- monitor sender
      msg <- receiveTimeout delay
                [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == ref)
                          (\_ -> return ()) ]
      case msg of
        Nothing -> kill sender "starting new promulgate action" >> go pid
        Just _  -> expect

remotable ['nodeUp]
