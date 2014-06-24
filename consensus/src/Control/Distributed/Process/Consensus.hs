-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Coherent groups, ie reliable processes made from unreliable ones.
--
-- The group acts as one coherent unit, just like a process. As such, its
-- members are called replicas. In particular, one can 'send' messages to the
-- group. The message will either be delivered to all correct replicas of the
-- group, or to none.

{-# LANGUAGE TemplateHaskell #-}

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
    , acceptorClosure
    , runPropose
    , runPropose'
      -- * Remote table
    , __remoteTable ) where

import Data.Lifted
import Control.Distributed.Process
import Control.Distributed.Process.Trans
import Control.Distributed.Process.Closure (mkStatic, remotable, staticDecode)
import Control.Distributed.Process.Serializable (Serializable, SerializableDict)
import Control.Distributed.Static
    ( closureApply
    , staticClosure )
import Control.Applicative (Applicative, (<$>))
import Control.Monad.Trans (lift)
import Control.Monad.State
    (MonadIO, StateT(..), get, modify)
import Data.Binary (Binary, encode)
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
    { decreeLegislatureId :: LegislatureId
    , decreeNumber        :: Int
    } deriving (Eq, Ord, Typeable, Generic)

instance Enum DecreeId where
    succ DecreeId{..} = DecreeId{decreeNumber=succ decreeNumber,..}
    pred DecreeId{..} = DecreeId{decreeNumber=pred decreeNumber,..}
    toEnum _   = error "toEnum: Cannot create DecreeId from Int."
    fromEnum _ = error "toEnum: Cannot create Int from DecreeId."
    enumFrom d              = map (\n -> d{decreeNumber=n}) $ enumFrom (decreeNumber d)
    enumFromThen d d'       = map (\n -> d{decreeNumber=n}) $
                              enumFromThen (decreeNumber d) (decreeNumber d')
    enumFromTo d d'         = map (\n -> d{decreeNumber=n}) $
                              enumFromTo (decreeNumber d) (decreeNumber d')
    enumFromThenTo d d' d'' = map (\n -> d{decreeNumber=n}) $
                              enumFromThenTo (decreeNumber d) (decreeNumber d') (decreeNumber d'')

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
runPropose m = fst <$> runStateT (unPropose m) Bottom

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
-- say to record the fact that has become a leader, which may be useful to
-- know to make future proposals more efficient. The type of the internal
-- state is kept abstract, through existential quantification, but since this
-- internal state is lifted, we know how to provide the initial state: it's
-- 'Bottom'.
data Protocol n a = forall s. Protocol
    { -- | An acceptor is spawned once on each replica, and survives until the
      -- replica fails.
      prl_acceptor :: n -> Process ()
      -- | @propose αs d x@ proposes decree value @x@ for decree @d@ to
      -- acceptors αs. Returns the decree value that was actually agreed upon.
      -- This value may be different from that which was proposed, in case
      -- another value was previously proposed for this decree.
      --
      -- This function produces an error if the decree @d@ has been garbage
      -- collected. Garbage collection is requested by the client with a
      -- function that is to be defined.
    , prl_propose  :: [ProcessId]                 -- Acceptors.
                   -> DecreeId
                   -> a
                   -> Propose s a
      -- XXX: add a function to perform garbage collection (old decrees that
      -- are of no use) in acceptors.
    } deriving (Typeable)

remotable ['prl_acceptor, 'initialDecreeId]

initialDecreeIdStatic :: Static DecreeId
initialDecreeIdStatic = $(mkStatic 'initialDecreeId)

acceptorClosure :: (Typeable a, Serializable n)
                => Static (SerializableDict n)
                -> Closure (Protocol n a)
                -> n
                -> Closure (Process ())
acceptorClosure dict protocol name = do
  staticClosure $(mkStatic 'prl_acceptor)
    `closureApply` protocol
    `closureApply` closure (staticDecode dict) (encode name)
