-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Replicate state machines and their logs. This module is intended to be
-- imported qualified.

module Control.Distributed.Log
    ( -- * Operations on handles
      Handle
    , updateHandle
    , remoteHandle
    , RemoteHandle
    , clone
      -- * Creating new log instances and operations
    , Hint(..)
    , Log(..)
    , Config(..)
    , LogId
    , toLogId
    , new
    , spawnReplicas
    , append
    , status
    , reconfigure
    , recover
    , monitorLog
    , monitorLocalLeader
    , getLeaderReplica
    , addReplica
    , killReplica
    , removeReplica
    , getMembership
      -- * Remote Tables
    , Control.Distributed.Log.Internal.__remoteTable
    ) where

import Control.Distributed.Log.Internal
