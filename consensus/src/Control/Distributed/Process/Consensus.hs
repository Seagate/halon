-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Coherent groups, ie reliable processes made from unreliable ones.
--
-- The group acts as one coherent unit, just like a process. As such, its
-- members are called replicas. In particular, one can 'send' messages to the
-- group. The message will either be delivered to all correct replicas of the
-- group, or to none.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE CPP #-}

module Control.Distributed.Process.Consensus
    ( -- * Decrees
      LegislatureId(..)
    , DecreeId(..)
    , initialDecreeId
    , initialDecreeIdStatic
      -- * The propose monad
    , module Data.Lifted
    , Propose
    , getState
    , setState
      -- * Consensus protocols
    , Protocol(..)
    , runPropose
    , runPropose'
      -- * Remote table
    , __remoteTable ) where

import Data.Lifted
import Control.Distributed.Process
import Control.Distributed.Process.Trans
import Control.Distributed.Process.Closure (mkStatic, remotable)
import Control.Distributed.Process.Serializable (Serializable)
#if ! MIN_VERSION_base(4,8,0)
import Control.Applicative (Applicative)
#endif
import Control.Monad.Trans (lift)
import Control.Monad.State
    (MonadIO, StateT(..), get, modify, evalStateT)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Prelude hiding (log)

-- NOTE ON NAMING: following convention, (see "The part-time parliament" by
-- Lamport) we use Greek letters for process identifiers.

newtype LegislatureId = LegislatureId Int
                      deriving (Bounded, Eq, Enum, Num, Ord, Typeable, Generic)

instance Show LegislatureId where
    show (LegislatureId l) = "legislature://" ++ show l

instance Binary LegislatureId

data DecreeId = DecreeId
    { decreeLegislatureId :: !LegislatureId
    , decreeNumber        :: !Int
    } deriving (Eq, Ord, Typeable, Generic)

instance Enum DecreeId where
    succ DecreeId{..} = DecreeId{decreeNumber=succ decreeNumber,..}
    pred DecreeId{..} = DecreeId{decreeNumber=pred decreeNumber,..}
    toEnum _   = error "toEnum: Cannot create DecreeId from Int."
    fromEnum _ = error "toEnum: Cannot create Int from DecreeId."
    enumFrom d              = map (\n -> d{decreeNumber=n}) $ enumFrom (decreeNumber d)
    enumFromThen (DecreeId l d) (DecreeId l' d')
      | l /= l'             = error "enumFromThen: legislature ids don't match"
      | otherwise           = map (DecreeId l) $ enumFromThen d d'
    enumFromTo (DecreeId l d) (DecreeId l' d')
      | l /= l'             = error "enumFromTo: legislature ids don't match"
      | otherwise           = map (DecreeId l) $ enumFromTo d d'
    enumFromThenTo (DecreeId l d) (DecreeId l' d') (DecreeId l'' d'')
      | l /= l' || l /= l'' = error "enumFromThenTo: legislature ids don't match"
      | otherwise           = map (DecreeId l) $ enumFromThenTo d d' d''

instance Show DecreeId where
    show (DecreeId (LegislatureId l) d) = "decree://" ++ show l ++ "/" ++ show d

instance Binary DecreeId

initialDecreeId :: DecreeId
initialDecreeId = DecreeId (LegislatureId 0) 0

-- | The Propose monad, in which proposals are made. It allows for internal
-- state to be carried forward between proposals. This is a transformed
-- 'Process' monad, so 'IO' and 'Process' actions can be lifted into it. The
-- internal state must increase monotonically over time. It is lifted in order
-- to provide a natural least state.
newtype Propose s a = Propose { unPropose :: StateT (Lifted s) Process a }
    deriving (Applicative, Functor, Monad, MonadIO, Typeable)

instance MonadProcess (Propose s) where
    liftProcess = Propose . lift

runPropose :: Propose s a -> Process a
runPropose m = evalStateT (unPropose m) Bottom

runPropose' :: Propose s a -> Lifted s -> Process (a,Lifted s)
runPropose' = runStateT . unPropose

getState :: Propose s (Lifted s)
getState = Propose $ get

-- | Set the state. Checks that state updates are strictly monotonic.
setState :: Ord s => s -> Propose s ()
setState x' = Propose $ modify check
  where check x
          | x < Value x' = Value x'
          | otherwise = error "setState: attempted to set state non-monotonically."

-- | A consensus protocol is characterized by the behaviour of acceptors, who
-- are the passive agents with voting rights, and that of one or more
-- proposers, who are the active agents that put forth proposals for
-- consensus.
--
-- Each time a proposal is made, the proposer may write to its internal state,
-- say to record the fact that he has become a leader, which may be useful to
-- know to make future proposals more efficient. The type of the internal
-- state is kept abstract, through existential quantification, but since this
-- internal state is lifted, we know how to provide the initial state: it's
-- 'Bottom'.
--
-- All fields take a function to use to send a message to acceptors
-- and one or more acceptors.
data Protocol n a = forall s. Protocol
    { -- | An acceptor is spawned once on each replica, and survives until the
      -- replica fails.
      prl_acceptor :: (forall b. Serializable b => n -> b -> Process ())
                   -> DecreeId -> n -> Process ()
      -- | @propose αs d x@ proposes decree value @x@ for decree @d@ to
      -- acceptors αs. Returns the decree value that was actually agreed upon.
      -- This value may be different from that which was proposed, in case
      -- another value was previously proposed for this decree.
      --
      -- This function produces an error if the decree @d@ has been garbage
      -- collected. Garbage collection can be requested by the client with an
      -- as yet to be defined method.
    , prl_propose
           :: (forall b. Serializable b => n -> b -> Process ())
           -> [n]
           -> DecreeId
           -> a
           -> Propose s a

      -- | Release decrees below a given decree. No call of 'prl_propose' should
      -- be done with these decrees afterwards.
    , prl_releaseDecreesBelow
           :: (forall b. Serializable b => n -> b -> Process ())
           -> n
           -> DecreeId
           -> Process ()

      -- | @prl_sync acceptors@ has the group of acceptors consider passed any
      -- decrees known to any acceptor.
      --
      -- This is useful to resize a group of acceptors where the state of
      -- individuals suffices to reconstruct the history but collectively there
      -- is not enough redundancy to determine the value of each decree.
      --
      -- All acceptors are scanned for existing decrees so they all need to be
      -- online.
      --
      -- This may have the effect of "completing" some proposals that were
      -- interrupted.
      --
      -- After this call, any value successfully proposed in the past is
      -- guaranteed to be remembered by the group.
      --
      -- Because it may not be possible to reconstruct the history for any
      -- possible change of the membership, it is up to the implementation to
      -- define the valid resizings.
      --
    , prl_sync :: (forall b. Serializable b => n -> b -> Process ())
               -> [n] -> Process ()

      -- | @prl_query acceptors d@ yields the values accepted by the given
      -- acceptors at or above the given decree.
      --
      -- It is up to the implementation to decide how many acceptors need to
      -- be online for the call to succeed.
    , prl_query :: (forall b. Serializable b => n -> b -> Process ())
                -> [n] -> DecreeId -> Process [(DecreeId, a)]

    } deriving (Typeable)

remotable ['initialDecreeId]

initialDecreeIdStatic :: Static DecreeId
initialDecreeIdStatic = $(mkStatic 'initialDecreeId)
