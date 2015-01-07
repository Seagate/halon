-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Logic for reporting a new Node has been added to the cluster. A NodeUp
-- process is spawned which is responsible for sending `NodeUp` messages
-- to the RC until it acknowledges, at which point the process dies.

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.NodeUp
  ( NodeUp(..)
  , nodeUp
  , nodeUp__static
  , nodeUp__sdict
  , __remoteTable
  )
where

import HA.EventQueue.Producer (promulgateEQ)

import Control.Distributed.Process
  ( NodeId
  , ProcessId
  , Process
  , expectTimeout
  , getSelfPid
  , say
  )
import Control.Distributed.Process.Closure ( remotable )

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)

-- | NodeUp message sent to the RC (via EQ) when a node starts.
newtype NodeUp = NodeUp ProcessId
  deriving (Eq, Show, Typeable, Binary, Hashable)

-- | Process which repeatedly sends 'NodeUp' messages to the EQ, until
--   one is acknowledged with a '()' reply.
nodeUp :: ( [NodeId] -- ^ Set of EQ nodes to contact
          , Int -- ^ Interval between sending messages (ms)
          )
       -> Process ()
nodeUp (eqs, delay) = getSelfPid >>= go
  where
    go pid = do
      say $ "Sending NodeUp message to " ++ show eqs
      _ <- promulgateEQ eqs $ NodeUp pid
      msg <- expectTimeout delay
      case msg of
        Nothing -> go pid
        Just () -> return ()

remotable ['nodeUp]
