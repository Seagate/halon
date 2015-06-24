-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Definitions common to all Paxos distributed algorithms, be they the basic
-- one or any optimizations thereof.

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
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
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Typeable
import Control.Monad

import Data.Maybe (isJust)
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
chooseValue :: DecreeId -> [Msg.Ack a] -> Maybe a
chooseValue d acks =
    if null acks'
    then Nothing
    else Just $ Msg.value $ maximumBy (compare `on` Msg.ballot) acks'
  where
    acks' = filter ((d ==) . Msg.decree) acks

{-*promela 99

inline chooseValue(p_x1,p_d,p_x,p_acks) {
  p_x1 = (p_acks.filled[p_d] -> p_acks.axs[p_d] : p_x);
}
*-}

-- | A persistent store for acceptor state
data AcceptorStore = AcceptorStore
    { -- | Inserts decrees in the store.
      storeInsert :: [(DecreeId, ByteString)] -> IO ()
      -- | Retrieves a decree in the store.
      --
      -- If the value was trimmed, it yields @Left True@.
      -- If the value was never stored, it yields @Left False@.
    , storeLookup :: DecreeId -> IO (Maybe ByteString)
      -- | Saves a value in the store.
    , storePut :: ByteString -> IO ()
      -- | Restores a value from the store.
    , storeGet :: IO (Maybe ByteString)
      -- | Trims state below the given decree.
    , storeTrim :: DecreeId -> IO ()
      -- | Lists the stored decrees.
    , storeList :: IO [(DecreeId, ByteString)]
      -- | Yields a map of the stored decrees.
    , storeMap :: IO (Map DecreeId ByteString)
      -- | Closes the store.
    , storeClose :: IO ()
    }
  deriving Typeable

-- | A type to ask acceptors to trim their state.
data Trim = Trim DecreeId
  deriving (Show, Typeable, Generic)

instance Binary Trim

-- | A tracing function for debugging purposes.
paxosTrace :: String -> Process ()
paxosTrace _ = return ()
-- paxosTrace msg = say $ "[paxos] " ++ msg

-- | Acceptor process.
--
-- Argument is a dummy to help resolve class constraints. Proper usage is
-- @acceptor (undefined :: a)@ where @a@ is a rigid type variable.
--
-- Invariant:
--
--   * P1. An acceptor can accept a proposal in ballot b iff it has not
--   responded to a 'Prepare' request in a ballot greater than b.
acceptor :: forall a n. (Serializable a, Serializable n)
         => (forall b. Serializable b => n -> b -> Process ())
         -> a -> DecreeId -> (n -> IO AcceptorStore) -> n -> Process ()
acceptor sendA _ startDecree0 config name =
  flip finally (paxosTrace "Acceptor terminated") $
  bracket (liftIO $ config name) (liftIO . storeClose) $ \case
  AcceptorStore {..} -> do
       liftIO storeGet >>= loop startDecree0 . maybe Bottom (Value . decode)
    where
      loop :: DecreeId -> Lifted BallotId -> Process b
      loop sd b = do
          paxosTrace "Acceptor waiting"
          receiveWait
              [ match $ \(Msg.Prepare d b' λ) ->
                  -- Don't reply if the value was trimmed.
                  -- The upper layers will have to figure out how
                  -- to get the trimmed values otherwise.
                  if (d < sd) then do
                    paxosTrace $ "Prepare: Trimmed " ++ show (d, b', λ)
                    loop sd b
                  else if b <= Value b'
                  then do
                    self <- getSelfPid
                    mbs <- liftIO (storeLookup d)
                    let acks Nothing = []
                        acks (Just bs) = let (b'', x) = decode bs
                                          in [Msg.Ack d b'' (x :: a)]
                    paxosTrace $ "Prepare: Promise " ++
                                 show (isJust mbs, d, b', λ)
                    usend λ $ Msg.Promise b' self $ acks mbs
                    loop sd (Value b')
                  else do
                    paxosTrace $ "Prepare: Nack " ++
                                 show (d, b', λ, fromValue b)
                    usend λ $ Msg.Nack $ fromValue b
                    loop sd b
              , match $ \(Msg.Syn d b' λ x) ->
                  -- Don't reply if the value was trimmed.
                  -- The upper layers will have to figure out how
                  -- to get the trimmed values otherwise.
                  if (d < sd) then loop sd b
                  else if b <= Value b'
                  then do
                    when (b < Value b') $
                      liftIO $ storePut $ encode b'
                    liftIO $ storeInsert [(d, encode (b', x :: a))]
                    paxosTrace $ "Syn: Ack " ++ show (d, b', λ)
                    usend λ $ Msg.Ack d b' x
                    loop sd (Value b')
                  else do
                    paxosTrace $ "Syn: Nack " ++ show (d, b', λ, fromValue b)
                    usend λ $ Msg.Nack $ fromValue b
                    loop sd b
              , match $ \(Trim d) -> do
                  liftIO $ storeTrim d
                  loop (max d sd) b

                -- Synchronization handlers

              , match $ \(Msg.SyncStart κ αs) -> do
                  paxosTrace $ "SyncStart " ++ show κ
                  -- Advertise the decrees we know about
                  dvs <- liftIO storeList
                  forM_ αs $ flip sendA $
                    Msg.SyncAdvertise κ name
                      (intervals $ map fst dvs)
                  loop sd b

              , match $ \(Msg.SyncAdvertise κ α ds) -> do
                  paxosTrace $ "SyncAdvertise " ++ show (κ, ds)
                  -- Request any missing decrees
                  dvs <- liftIO storeList
                  let rqs = diffIntervals ds $
                              if initialDecreeId < sd then
                                (initialDecreeId, sd) :
                                  intervals (dropWhile (<sd) $ map fst dvs)
                              else
                                intervals (map fst dvs)
                  if null rqs then do
                    usend κ $ Msg.SyncCompleted name
                  else
                    sendA α $ Msg.SyncRequest κ name rqs
                  loop sd b

              , match $ \(Msg.SyncRequest κ α ds) -> do
                  paxosTrace $ "SyncRequest " ++ show (κ, ds)
                  -- Reply with the values for the missing decrees
                  let lookupRanges _ [] = []
                      lookupRanges m ((d0, d1) : dps) =
                        let (_, mv0, m') = Map.splitLookup d0 m
                            (mvs, m'') = Map.split d1 m'
                        in maybe id (\v0 -> ((d0, v0):)) mv0 $
                             Map.assocs mvs ++ lookupRanges m'' dps
                  m <- liftIO storeMap
                  sendA α $ Msg.SyncResponse κ $ lookupRanges m ds
                  loop sd b

              , match $ \(Msg.SyncResponse κ dvs) -> do
                  paxosTrace $ "SyncResponse " ++ show (κ, map fst dvs)
                  liftIO $ storeInsert dvs
                  usend κ $ Msg.SyncCompleted name
                  loop sd b

                -- querying decrees
              , match $ \(Msg.QueryDecrees κ d) -> do
                  paxosTrace $ "QueryDecrees " ++ show (κ, d)
                  m <- liftIO storeMap
                  let (_, mv, m') = Map.splitLookup d m
                      acks = [ Msg.Ack di b' v
                             | (di, bs) <- maybe id ((:) . (d,)) mv $
                                             Map.assocs m'
                             , let (b', v) = decode bs :: (BallotId, a)
                             ]
                  usend κ acks
                  loop sd b
              ]

-- > expand . intervals == intervals . expand == id
-- >   where
-- >     expand = concatMap (\(x, y) -> [x .. pred y])
--
-- forall x, y, u, v, w, xs: @sorted xs@ implies
--
-- > all (uncurry (<)) (intervals xs)
-- > && [(u, v), (w, x)] `isInfixOf` intervals xs ==> v < w
--
intervals :: (Enum a, Eq a) => [a] -> [(a, a)]
intervals (x0 : xs0) = go x0 (succ x0) xs0
  where
    -- invariant: @x < y@
    -- invariant: @all (y<) xs@
    -- invariant: @[x .. pred y] `isPrefixOf` head (go x y xs)@
    go x y (z : xs) | y == z    = go x (succ z) xs
                    | otherwise = (x, y) : go z (succ z) xs
    go x y [] = [(x, y)]
intervals  [] = []

-- | @expand xs \\ expand ys == expand (diffIntervals xs ys)@
diffIntervals :: Ord a => [(a, a)] -> [(a, a)] -> [(a, a)]
diffIntervals xs [] = xs
diffIntervals [] _ys = []
diffIntervals ((x, x') : xss) ys@((y, y') : yss)
  | x < y' && y < x' =
    if x < y then (x, y) : diffIntervals xss ys
    else if x' <= y' then diffIntervals xss ys
         else diffIntervals ((y', x') : xss) yss
  | otherwise = (x, x') : diffIntervals xss ys

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
