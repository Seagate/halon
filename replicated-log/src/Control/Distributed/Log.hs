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
    , new
    , append
    , status
    , reconfigure
    , addReplica
    , killReplica
    , removeReplica
      -- * Remote Tables
    , Control.Distributed.Log.Internal.__remoteTable
    , Control.Distributed.Log.Internal.__remoteTableDecl
    , ambassador__tdict
    ) where

import Control.Distributed.Log.Internal
