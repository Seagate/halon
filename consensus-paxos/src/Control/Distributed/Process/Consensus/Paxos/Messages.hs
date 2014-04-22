-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Control.Distributed.Process.Consensus.Paxos.Messages where

import Control.Distributed.Process.Consensus (DecreeId(..))
import Control.Distributed.Process.Consensus.Paxos.Types
import Control.Distributed.Process (ProcessId)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)


-- A ballot is both locally unique to a replica, and globally unique by
-- including the globally unique identifier (the ProcessId) of the replica.
-- However, messages from the unique proposer of the replica still include
-- a "Reply-To" 'ProcessId', because the message could be sent by a utility
-- child process rather than the proposer itself.

data Prepare = Prepare DecreeId BallotId ProcessId
               deriving (Typeable, Generic)

data Promise a = Promise BallotId ProcessId [Ack a]
                 deriving (Typeable, Generic)

data Nack = Nack BallotId
            deriving (Typeable, Generic)

data Syn a = Syn DecreeId BallotId ProcessId a
             deriving (Typeable, Generic)

data Ack a = Ack DecreeId BallotId ProcessId a
             deriving (Typeable, Generic)

instance Binary Prepare
instance Binary a => Binary (Promise a)
instance Binary Nack
instance Binary a => Binary (Syn a)
instance Binary a => Binary (Ack a)

class Decree a where
  decree :: a -> DecreeId

instance Decree (Syn a) where
  decree (Syn d _ _ _) = d

instance Decree (Ack a) where
  decree (Ack d _ _ _) = d

class Ballot a where
  ballot :: a -> BallotId

instance Ballot Prepare where
  ballot (Prepare _ b _) = b

instance Ballot (Promise a) where
  ballot (Promise b _ _) = b

instance Ballot Nack where
  ballot (Nack b) = b

instance Ballot (Syn a) where
  ballot (Syn _ b _ _) = b

instance Ballot (Ack a) where
  ballot (Ack _ b _ _) = b

class Value a where
  value :: a v -> v

instance Value Syn where
  value (Syn _ _ _ x) = x

instance Value Ack where
  value (Ack _ _ _ x) = x
