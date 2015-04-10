-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Definitions common to all Paxos distributed algorithms, be they the basic
-- one or any optimizations thereof.

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE KindSignatures #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Process.Consensus.Paxos
    ( chooseValue
    , acceptor
    , AcceptorStore(..)
    , Trim(..)
    ) where

import Prelude hiding ((<$>), (<*>))
import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos.Types
import qualified Control.Distributed.Process.Consensus.Paxos.Messages as Msg
import Control.Distributed.Process
import Control.Distributed.Process.Serializable

import Data.Binary (Binary, encode, decode)
import Data.ByteString.Lazy (ByteString)
import Data.Typeable
import Control.Monad

import Data.List (maximumBy)
import Data.Function (on)
import GHC.Generics (Generic)


-- Note [Naming]
-- ~~~~~~~~~~~~~
-- Following convention, (see "The part-time parliament" by Lamport) we use
-- Greek letters for process identifiers.
--
-- In Emacs, use M-x set-input-method RET TeX to input Greek characters
-- easily.
--
-- Note [Message Typing]
-- ~~~~~~~~~~~~~~~~~~~~~
-- Make sure to match the instantiation of type variable @a@ between the
-- acceptors and the proposers. Otherwise promises, acks, etc sent from one to
-- the other will be silently ignored. This can be rather befuddling.
--
-- Note [Paxos Invariants]
-- ~~~~~~~~~~~~~~~~~~~~~~~
-- (Source: "The part-time parliament", Leslie Lamport (1998).)
--
-- A ballot consists of:
--
--   * A decree (the one being voted on).
--
--   * A non-empty set of participants (the ballot's quorum).
--
--   * The set of participants that voted for the decree.
--
--   * A ballot number
--
-- A successful ballot is one in which every quorum member voted. Let B be
-- a set of ballots. Then,
--
--   * B1. Each ballot in B has a unique ballot number.
--
--   * B2. The quorums of any two ballots in B have at least one member in
--   common.
--
--   * B3. For every ballot b in B, if any member of B's quorum voted in an
--   earlier ballot in B, then the decree of b equals the decree of the latest
--   of those earlier ballots.

-- | Choose the value @x@ of any vote pertaining to the given decree number in
-- the highest ballot.
chooseValue :: DecreeId -> a -> [Msg.Ack a] -> a
chooseValue d def acks =
    if null acks'
    then def
    else Msg.value $ maximumBy (compare `on` Msg.ballot) acks'
  where
    acks' = filter ((d ==) . Msg.decree) acks

{-*promela 99

inline chooseValue(p_x1,p_d,p_x,p_acks) {
  p_x1 = (p_acks.filled[p_d] -> p_acks.axs[p_d] : p_x);
}
*-}

type Trimmed = Bool

-- | A persistent store for acceptor state
data AcceptorStore = AcceptorStore
    { -- | Inserts a decree in the store.
      storeInsert :: DecreeId -> ByteString -> IO ()
      -- | Retrieves a decree in the store.
      --
      -- If the value was trimmed, it yields @Left True@.
      -- If the value was never stored, it yields @Left False@.
    , storeLookup :: DecreeId -> IO (Either Trimmed ByteString)
      -- | Saves a value in the store.
    , storePut :: ByteString -> IO ()
      -- | Restores a value from the store.
    , storeGet :: IO (Maybe ByteString)
      -- | Trims state below the given decree.
    , storeTrim :: DecreeId -> IO ()
      -- | Closes the store.
    , storeClose :: IO ()
    }
  deriving Typeable

-- | A type to ask acceptors to trim their state.
data Trim = Trim DecreeId
  deriving (Show, Typeable, Generic)

instance Binary Trim

-- | Acceptor process.
--
-- Argument is a dummy to help resolve class constraints. Proper usage is
-- @acceptor (undefined :: a)@ where @a@ is a rigid type variable.
--
-- Invariant:
--
--   * P1. An acceptor can accept a proposal in ballot b iff it has not
--   responded to a 'Prepare' request in a ballot greater than b.
acceptor :: forall a n. Serializable a
         => a -> (n -> IO AcceptorStore) -> n -> Process ()
acceptor _ config name =
  bracket (liftIO $ config name) (liftIO . storeClose) $ \case
  AcceptorStore {..} -> do
       liftIO storeGet >>= loop . maybe Bottom (Value . decode)
    where
      loop :: Lifted BallotId -> Process b
      loop b = do
          self <- getSelfPid
          receiveWait
              [ match $ \(Msg.Prepare d b' λ) -> do
                  if b <= Value b'
                  then do
                      when (b < Value b') $
                        liftIO $ storePut $ encode b'
                      ebs <- liftIO $ storeLookup d
                      case ebs of
                        Left True ->
                          -- Don't reply if the value was trimmed.
                          -- The upper layers will have to figure out how
                          -- to get the trimmed values otherwise.
                          return ()
                        Left False ->
                          usend λ $ Msg.Promise b' self ([] :: [Msg.Ack a])
                        Right bs -> do
                          let (b'', x) = decode bs
                          usend λ $ Msg.Promise b' self
                                                [Msg.Ack d b'' self (x :: a)]
                      loop (Value b')
                  else do
                      usend λ $ Msg.Nack $ fromValue b
                      loop b
              , match $ \(Msg.Syn d b' λ x) -> do
                  if b <= Value b'
                  then do
                      when (b < Value b') $
                        liftIO $ storePut $ encode b'
                      liftIO $ storeInsert d $ encode (b', x :: a)
                      usend λ $ Msg.Ack d b' self x
                      loop (Value b')
                  else do
                      usend λ $ Msg.Nack $ fromValue b
                      loop b
              , match $ \(Trim d) -> do
                  liftIO $ storeTrim d
                  loop b
              ]

{-*promela

/**
 * The main difference with the Haskell code is that we have to assume a
 * fixed-size buffer of acks.
 */
proctype Acceptor(short self) {
  Acks acks;
  Msg msg;
  Msg acc_msg;
  Ballot b;
  ballot_ini(b);
end:
  do
  :: receive(self,PREPARE, msg) ->
       if
       :: ballotcmp(b,msg.b) <= 0 ->
            d_step {
              ballotcpy(acc_msg.b,msg.b);
              if
              :: acks.filled[msg.d] ->
                   acc_msg.has_decree = 1;
                   acc_msg.x = acks.axs[msg.d];
                   acc_msg.d = msg.d;
              :: else ->
                   acc_msg.has_decree = 0;
              fi;
              acc_msg.mpid = self;
              ballotcpy(b,msg.b)
            }
            send(msg.mpid,PROMISE,acc_msg);
       :: else ->
            d_step {
              ballotcpy(acc_msg.b,b);
            }
            send(msg.mpid,NACK,acc_msg)
       fi
  :: receive(self,SYN, msg) ->
       if
       :: ballotcmp(b,msg.b) <= 0 ->
            d_step {
              acc_msg.d = msg.d;
              ballotcpy(acc_msg.b,msg.b);
              acc_msg.mpid = self;
              acc_msg.x = msg.x;
              ballotcpy(b,msg.b)
              addack(acks,msg)
            }
            send(msg.mpid,ACK,acc_msg);
       :: else ->
            d_step {
              ballotcpy(acc_msg.b,b);
            }
            send(msg.mpid,NACK,acc_msg)
       fi
  od
}
*-}
