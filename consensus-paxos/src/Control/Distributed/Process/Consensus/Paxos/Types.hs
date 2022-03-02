-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

module Control.Distributed.Process.Consensus.Paxos.Types where

import Control.Distributed.Process.Internal.Types
    (ProcessId(..), NodeId(..), LocalProcessId(..))
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)


type ProposalId = Int

-- | The order of the fields is relevant here, if one wants to use the default
-- 'Ord' instance.
data BallotId = BallotId
    { ballotProposalId :: {-# UNPACK #-} !ProposalId
    , ballotProcessId  :: {-# UNPACK #-} !ProcessId
    } deriving (Eq, Ord, Typeable, Generic)

instance Binary BallotId

instance Show BallotId where
    show BallotId{ ballotProcessId =
                       ProcessId (NodeId addr) (LocalProcessId _ lid), ..} =
        "ballot://" ++ show addr
        ++ ":" ++ show lid
        ++ "/" ++ show ballotProposalId

-- | Given a ballot identifier @b@, return a ballot identifier @b'@ such that
-- @b < b'@.
nextBallotId :: BallotId -> BallotId
nextBallotId (BallotId{..}) =
    BallotId { ballotProposalId = succ ballotProposalId, .. }
