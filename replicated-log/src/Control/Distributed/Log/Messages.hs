-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Log.Messages where

import Control.Distributed.Log.Policy (NominationPolicy)
import Control.Distributed.Process.Consensus (DecreeId)
import Control.Distributed.Process (ProcessId)
import Control.Distributed.Static (Closure)
import Control.Distributed.Process.Consensus (LegislatureId)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Data.Binary (Binary)


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

instance Binary Helo

--------------------------------------------------------------------------------
-- Inter-replica messages                                                     --
--------------------------------------------------------------------------------

-- | Ack to client local decrees, don't ack remote decrees. Since each decree is
-- local to at least one replica, the client will get at least one ack.
data Locale = Local ProcessId | Remote | Stored
    deriving (Eq, Show, Typeable, Generic)

-- | Signal other replicas that consensus has just been reached on a decree.
data Decree a = Decree Locale DecreeId a
    deriving (Typeable, Generic)

-- | Replica asking another replica what the value of a given decree number is.
data Query = Query ProcessId Int
    deriving (Typeable, Generic)

data Max = Max ProcessId DecreeId [ProcessId] [ProcessId]
    deriving (Typeable, Generic)

-- | Reports the snapshot of a replica upon receiving a 'Query' for an
-- old-enough decree.
--
-- It also reports the current membership and legislature.
--
-- > SnapshotInfo acceptors replicas legislatureId snapshotRef
-- >              snapshotWatermark oldDecree
--
data SnapshotInfo ref = SnapshotInfo [ProcessId] [ProcessId] LegislatureId ref
                                     DecreeId Int
    deriving (Typeable, Generic)

instance Binary Locale
instance Binary a => Binary (Decree a)
instance Binary Query
instance Binary Max
instance Binary ref => Binary (SnapshotInfo ref)
