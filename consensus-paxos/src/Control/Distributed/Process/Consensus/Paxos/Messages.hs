-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

module Control.Distributed.Process.Consensus.Paxos.Messages where

import Control.Distributed.Process.Consensus (DecreeId(..))
import Control.Distributed.Process.Consensus.Paxos.Types
import Control.Distributed.Process (ProcessId)
import Data.Binary (Binary)
import qualified Data.ByteString.Lazy as BSL (ByteString)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)


-- A ballot is both locally unique to a replica, and globally unique by
-- including the globally unique identifier (the ProcessId) of the replica.
-- However, messages from the unique proposer of the replica still include
-- a "Reply-To" 'ProcessId', because the message could be sent and replies
-- could be expected by a utility child process rather than the proposer
-- itself.
--
-- The 'Promise' and 'Ack' messages sent as replies by acceptors also
-- contain the @ProcessId@ of the acceptor sending them. This is so
-- that the replica could count how many different acceptors sent
-- positive replies and establish a quorum.

-- | First phase message sent by a proposer to the acceptors.
data Prepare = Prepare DecreeId BallotId ProcessId
               deriving (Typeable, Generic)

-- | Positive reply to a 'Prepare' message.
--
-- @[Ack a]@ List of the (relevant) @Ack@s produced by the acceptor
-- for the @DecreeId@ that was in the @Prepare@ message this is a
-- response to.
--
-- TODO: https://app.asana.com/0/12314345447678/16174328143405
data Promise a = Promise BallotId ProcessId [Ack a]
                 deriving (Typeable, Generic)

-- | Negative reply to either 'Prepare' or 'Syn'.
data Nack = Nack BallotId
            deriving (Typeable, Generic)

-- | Second phase message sent by a proposer to the acceptors.
data Syn a = Syn DecreeId BallotId ProcessId a
             deriving (Typeable, Generic)

-- | Positive reply to a 'Syn'.
data Ack a = Ack DecreeId BallotId a
             deriving (Typeable, Generic)

data SyncStart n = SyncStart ProcessId [n]
  deriving (Typeable, Generic)

data SyncAdvertise n = SyncAdvertise ProcessId n [(DecreeId, DecreeId)]
  deriving (Typeable, Generic)

data SyncRequest n = SyncRequest ProcessId n [(DecreeId, DecreeId)]
  deriving (Typeable, Generic)

data SyncResponse = SyncResponse ProcessId [(DecreeId, BSL.ByteString)]
  deriving (Typeable, Generic)

data SyncCompleted n = SyncCompleted n
  deriving (Typeable, Generic)

data QueryDecrees = QueryDecrees ProcessId DecreeId
  deriving (Typeable, Generic)

instance Binary Prepare
instance Binary a => Binary (Promise a)
instance Binary Nack
instance Binary a => Binary (Syn a)
instance Binary a => Binary (Ack a)
instance Binary n => Binary (SyncStart n)
instance Binary n => Binary (SyncAdvertise n)
instance Binary n => Binary (SyncRequest n)
instance Binary n => Binary (SyncCompleted n)
instance Binary SyncResponse
instance Binary QueryDecrees

class Decree a where
  decree :: a -> DecreeId

instance Decree (Syn a) where
  decree (Syn d _ _ _) = d

instance Decree (Ack a) where
  decree (Ack d _ _) = d

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
  ballot (Ack _ b _) = b

class Value a where
  value :: a v -> v

instance Value Syn where
  value (Syn _ _ _ x) = x

instance Value Ack where
  value (Ack _ _ x) = x
