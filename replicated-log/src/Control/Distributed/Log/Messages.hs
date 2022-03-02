-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Log.Messages where

import Control.Distributed.Log.Policy (NominationPolicy)
import Control.Distributed.Process.Consensus (DecreeId)
import Control.Distributed.Process (ProcessId, NodeId)
import Control.Distributed.Static (Closure)
import Control.Distributed.Process.Consensus (LegislatureId)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Data.Binary (Binary)
import System.Clock (TimeSpec)


--------------------------------------------------------------------------------
-- Ambassador messages                                                        --
--------------------------------------------------------------------------------

-- | Message sent to an ambassador to clone a remote handle locally.
data Clone = Clone ProcessId
    deriving (Typeable, Generic)

instance Binary Clone

--------------------------------------------------------------------------------
-- Reconf messages                                                            --
--------------------------------------------------------------------------------

-- | Greeting message proposing a new member, so-named after the eponymous SMTP
-- command.
data Helo =
    Helo ProcessId                    -- Process asking for reconfiguration.
         (Closure NominationPolicy)   -- Policy to decide new membership.
    deriving (Typeable, Generic)

-- | @Recover sender newMembership@
data Recover = Recover ProcessId [NodeId]
  deriving (Typeable, Generic, Show)

instance Binary Helo
instance Binary Recover

--------------------------------------------------------------------------------
-- Inter-replica messages                                                     --
--------------------------------------------------------------------------------

-- | Ack to clients local decrees, don't ack remote decrees. Since each decree
-- is local to at least one replica, the clients will get at least one ack.
--
-- 'Local' carries the list of client pids to ack and the pids of internal
-- processes to ack as well.
data Locale = Local [ProcessId] [ProcessId] | Remote | Stored
    deriving (Eq, Show, Typeable, Generic)

-- | Signal other replicas that consensus has just been reached on a decree.
data Decree a = Decree TimeSpec Locale DecreeId a
    deriving (Typeable, Generic)

-- | Orphan
instance Binary TimeSpec

-- | Replica asking another replica what the value of a given decree number is.
data Query = Query ProcessId Int
    deriving (Typeable, Generic)

data ConfigQuery = ConfigQuery ProcessId
    deriving (Typeable, Generic)

data MembershipQuery = MembershipQuery ProcessId
    deriving (Typeable, Generic)

data Max = Max ProcessId DecreeId DecreeId LegislatureId [NodeId]
    deriving (Typeable, Generic)

-- | Reports the snapshot of a replica upon receiving a 'Query' for an
-- old-enough decree.
--
-- It also reports the current membership, the legislature and the epoch.
--
-- > SnapshotInfo replicas legislatureId epoch snapshotRef
-- >              snapshotWatermark oldDecree
--
data SnapshotInfo ref = SnapshotInfo [NodeId] DecreeId
                                     LegislatureId ref DecreeId Int
    deriving (Typeable, Generic)

instance Binary Locale
instance Binary a => Binary (Decree a)
instance Binary Query
instance Binary ConfigQuery
instance Binary Max
instance Binary MembershipQuery
instance Binary ref => Binary (SnapshotInfo ref)
