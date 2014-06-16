-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is intended to be imported qualified.

{-# LANGUAGE TemplateHaskell #-}

module Control.Distributed.Process.Consensus.BasicPaxos
    ( propose
    , protocol
    , protocolClosure
    , __remoteTable
    , dictString__static
    ) where

import Control.Distributed.Process.Consensus hiding (__remoteTable)
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Consensus.Paxos.Types
import qualified Control.Distributed.Process.Consensus.Paxos.Messages as Msg
import Control.Distributed.Process.Quorum
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Trans (liftProcess)
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Distributed.Static
    ( closureApply
    , staticClosure )
import Control.Applicative ((<$>))
import Control.Concurrent ( newEmptyMVar, putMVar, takeMVar, threadDelay )
import Control.Exception ( SomeException, throwIO )
import Control.Monad (when)
import Data.Binary ( Binary )
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import System.Random ( randomRIO )

-- | An internal type used only by 'callLocal'.
data Done = Done
  deriving (Typeable,Generic)

instance Binary Done

-- | Local version of 'call', just as 'spawnLocal' is a local version of
-- 'spawn'. Spinning an action into its own process in this way isolates it
-- from messages that it does not intend to process / makes outdated messages
-- disappear on their own without having to explicitly pluck them out of the
-- mailbox.
callLocal :: Process a -> Process a
callLocal p = do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  _ <- spawnLocal $ link self >> try p >>= liftIO . putMVar mv
                      >> when schedulerIsEnabled (send self Done)
  when schedulerIsEnabled $ do Done <- expect; return ()
  liftIO $ takeMVar mv
    >>= either (throwIO :: SomeException -> IO a) return

scout :: forall a. Serializable a =>
         [ProcessId] -> DecreeId -> BallotId ->
         Process (Either BallotId [Msg.Ack a])
scout acceptors d b = callLocal $ do
  self <- getSelfPid
  let clauses = [ match $ \(Msg.Nack b') -> return $ Left b'
                , match $ \(Msg.Promise _ _ acks) -> return $ Right acks
                ]
  fmap concat <$> expectQuorum clauses acceptors (Msg.Prepare d b self)

{-*promela

inline scout(self,d,b,success,tb,acks) {
  byte i = 0;
  Msg msg;
  d_step {
    msg.mpid = self;
    ballotcpy(msg.b,b);
    msg.d = d;
  }
  do
  :: i < PROCS -> send(i,PREPARE,msg); i++
  :: else -> break
  od;
  i = PROCS / 2 + 1;
  do
  :: atomic {
       i > 0;
       poll(self,_,_);
       if
       :: poll(self,NACK,msg) ->
            d_step {
              receive(self,NACK,msg);
              ballotcpy(tb,msg.b);
              success = 0;
            }
            break
       :: else ->
            if
            :: poll(self,PROMISE,msg) ->
                 d_step {
                   receive(self,PROMISE,msg);
                   if
                   :: ballotcmp(msg.b,b) == 0 ->
                        addack(acks,msg);
                        i--
                   :: else -> skip
                   fi
                 }
            :: else -> skip
            fi
       fi
     }
  :: else ->
       success= 1;
       break
  od;
}
*-}

-- Return type is isomorphic to @Maybe BallotId@, but use 'Either' because it
-- would be confusing to use 'Nothing' as a value to indicate that everything
-- went normally, i.e. that we were not preempted.
command :: forall a. Serializable a
        => [ProcessId]
        -> DecreeId
        -> BallotId
        -> a
        -> Process (Either BallotId ())
command acceptors d b x = callLocal $ do
  self <- getSelfPid
  let clauses = [ match $ \(Msg.Nack b') -> return $ Left b'
                , match $ \(_ :: Msg.Ack a) -> return $ Right ()
                ]
  fmap (const ()) <$> expectQuorum clauses acceptors (Msg.Syn d b self x)

{-*promela

inline command(self,success,tb,d,b,x1) {

  byte i = 0;
  Msg msg;
  d_step {
    msg.d = d;
    ballotcpy(msg.b,b);
    msg.mpid = self;
    msg.x = x1;
    msg.has_decree = 1;
  }
  do
  :: i < PROCS -> send(i,SYN,msg); i++
  :: else -> break
  od;
  i = PROCS / 2 + 1;
  do
  :: atomic {
       i > 0;
       poll(self,_,_);
       if
       :: poll(self,NACK,msg) ->
            d_step {
              receive(self,NACK,msg);
              ballotcpy(tb,msg.b);
              success = 0;
            }
            break
       :: else ->
            if
            :: poll(self,ACK,msg) ->
                 d_step {
                   receive(self,ACK,msg);
                   if
                   :: ballotcmp(msg.b,b) == 0 -> i--
                   :: else -> skip
                   fi
                 }
            :: else -> skip
            fi
       fi
     }
  :: else ->
       success= 1;
       break
  od
}
*-}

-- | Basic Paxos proposers do not keep state across proposals.
propose :: Serializable a
        => [ProcessId]
        -> DecreeId
        -> a
        -> Propose () a
propose acceptors d x = liftProcess $ do
  self <- getSelfPid
  loop (BallotId 0 self)
    where loop b = do
            eth <- scout acceptors d b
            case eth of
              Left b'@BallotId{..} -> do
                  when (not schedulerIsEnabled) $
                    liftIO $ randomRIO (0,1000000) >>= threadDelay
                  if b < b' then loop (nextBallotId b{ballotProposalId}) else loop b
              Right xs -> do
                  let x' = chooseValue d x xs
                  eth' <- command acceptors d b x'
                  case eth' of
                      Left BallotId{..} -> do
                        when (not schedulerIsEnabled) $
                          liftIO $ randomRIO (0,1000000) >>= threadDelay
                        loop b{ballotProposalId}
                      Right _ -> return x'

protocol :: forall a n. SerializableDict a
         -> (n -> FilePath)
         -> Protocol n a
protocol SerializableDict f =
    Protocol { prl_acceptor = acceptor (undefined :: a) f
             , prl_propose = propose }

dictString :: SerializableDict String
dictString = SerializableDict

remotable ['protocol, 'dictString]

protocolClosure :: (Typeable a, Typeable n)
                => Static (SerializableDict a)
                -> Closure (n -> FilePath)
                -> Closure (Protocol n a)
protocolClosure sdict fp =
    staticClosure $(mkStatic 'protocol)
      `closureApply` staticClosure sdict
      `closureApply` fp

{-*promela

proctype Proposer(short self) {
  Ballot b, tb;
  ballot_ini(b);
  Acks acks;
  bit success = 0;
  short child;
  byte d, x, x1, proposalCount = 0;
  d_step {
    b.bpid = self;
    b.bottom = 0;
    b.n = 0;
  }

  do
  :: proposalCount < AMOUNT_OF_PROPOSALS ->

     select(d : 0 .. (ACKS_LEN-1));
     select(x : 0 .. (ACKS_LEN-1));

     clear_acks(acks);

     generatePid(child);
     scout(child,d,b,success,tb,acks);
     disposePid(child);

     if
     :: !success ->
          d_step {
            if
            :: ballotcmp(b,tb) < 0 -> b.n = tb.n+1
            :: else -> skip
            fi
          }
     :: success ->
          d_step {
            chooseValue(x1,d,x,acks);
          }
          generatePid(child);
          command(child,success,tb,d,b,x1);
          disposePid(child);
          if
          :: success ->
value_accepted:
               d_step {
                 if
                 :: pxs[d].b[self-PROCS] == 255 ->
                      pxs[d].b[self-PROCS] = x1;
                      checkAgreement();
                 :: else -> assert(pxs[d].b[self-PROCS] == x1)
                 fi;
                 printf("%d - decree %d: %d\n",self,d,x1);
                 proposalCount++;
                 b.bpid = self;
                 b.bottom = 0;
                 b.n = 0;
               }
          :: else -> b.n = tb.n
          fi
     fi;
  :: else -> break
  od
}
*-}
