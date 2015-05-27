-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
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
    , addReplica
    , killReplica
    , removeReplica
      -- * Remote Tables
    , Control.Distributed.Log.Internal.__remoteTable
    ) where

import Control.Distributed.Log.Internal
