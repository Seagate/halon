-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is intended to be imported qualified.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE KindSignatures #-}

module Control.Distributed.Process.Consensus.BasicPaxos
    ( propose
    , protocol
    , protocolClosure
    , __remoteTable
    , dictString__static
    ) where

import Prelude hiding ((<$>))
import Control.Distributed.Process.Consensus hiding (__remoteTable)
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Consensus.Paxos.Types
import qualified Control.Distributed.Process.Consensus.Paxos.Messages as Msg
import Control.Distributed.Process.Quorum
import Control.Distributed.Process hiding (callLocal)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( runLocalProcess )
import Control.Distributed.Process.Trans (liftProcess)
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Distributed.Static
    ( closureApply
    , staticClosure )
import Control.Applicative ((<$>))
import Control.Concurrent ( newEmptyMVar, putMVar, takeMVar, threadDelay )
import Control.Exception ( SomeException, throwIO )
import Control.Monad (when, forM_)
import Control.Monad.Reader ( ask )
import Data.Binary ( Binary )
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import System.Random ( randomRIO )
import qualified System.Timeout as T ( timeout )


-- | An internal type used only by 'callLocal'.
data Done = Done
  deriving (Typeable,Generic)

instance Binary Done

-- XXX pending inclusion of a fix to callLocal upstream.
--
-- https://github.com/haskell-distributed/distributed-process/pull/180
callLocal :: Process a -> Process a
callLocal p = mask_ $ do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  pid <- spawnLocal $ try p >>= liftIO . putMVar mv
                      >> when schedulerIsEnabled (usend self Done)
  when schedulerIsEnabled $ do Done <- expect; return ()
  liftIO (takeMVar mv >>= either (throwIO :: SomeException -> IO a) return)
    `onException` do
       -- Exit the worker and wait for it to terminate.
       bracket (monitor pid) unmonitor $ \ref -> do
         exit pid "callLocal was interrupted"
         receiveWait
           [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                     (const $ return ())
           ]

-- | Retries an action every certain amount of microseconds until it completes
-- within the given time interval.
--
-- The action is interrupted, if necessary, to retry.
--
retry :: Int  -- ^ Amount of microseconds between retries
      -> Process a -- ^ Action to perform
      -> Process a
retry t action = timeout t action >>= maybe (retry t action) return

-- | Spawns a local process and has it linked to the parent.
spawnLocalLinked :: Process () -> Process ProcessId
spawnLocalLinked p = do
  self <- getSelfPid
  spawnLocal $ link self >> p

-- | A version of 'System.Timeout.timeout' for the 'Process' monad.
timeout :: Int -> Process a -> Process (Maybe a)
timeout t action
    | schedulerIsEnabled = fmap Just action
    | otherwise = ask >>= liftIO . T.timeout t . (`runLocalProcess` action)

-- | A tracing function for debugging purposes.
paxosTrace :: String -> Process ()
paxosTrace _ = return ()
-- paxosTrace msg = say $ "[paxos] " ++ msg

scout :: Serializable a
      => (forall b. Serializable b => n -> b -> Process ())
      -> [n] -> DecreeId -> BallotId -> Process (Either BallotId [Msg.Ack a])
scout sendA acceptors d b = callLocal $ do
  paxosTrace $ "scout: " ++ show (d, b)
  self <- getSelfPid
  let clauses = [ match $ \(Msg.Nack b') -> return $ Left b'
                , match $ \(Msg.Promise _ _ acks) -> return $ Right acks
                ]
  forM_ acceptors $ spawnLocalLinked . flip sendA (Msg.Prepare d b self)
  fmap concat <$> expectQuorum clauses (length acceptors)

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
command :: forall a n. Serializable a
        => (forall b. Serializable b => n -> b -> Process ())
        -> [n]
        -> DecreeId
        -> BallotId
        -> a
        -> Process (Either BallotId ())
command sendA acceptors d b x = callLocal $ do
  paxosTrace $ "command: " ++ show (d, b)
  self <- getSelfPid
  let clauses = [ match $ \(Msg.Nack b') -> return $ Left b'
                , match $ \(_ :: Msg.Ack a) -> return $ Right ()
                ]
  forM_ acceptors $ spawnLocalLinked . flip sendA (Msg.Syn d b self x)
  fmap (const ()) <$> expectQuorum clauses (length acceptors)

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
        => Int
        -> (forall b. Serializable b => n -> b -> Process ())
        -> [n]
        -> DecreeId
        -> a
        -> Propose () a
propose retryTimeout sendA acceptors d x = liftProcess $
  (do self <- getSelfPid
      loop 0 (BallotId 0 self)
  ) `onException` paxosTrace "terminated with exception"
    where loop backoff b = do
            eth <- retry retryTimeout $ scout sendA acceptors d b
            let backoff' = if backoff == 0 then 200000 else 2 * backoff
            case eth of
              Left b'@BallotId{..} -> do
                  paxosTrace $ "propose: scout failed " ++ show b'
                  when (not schedulerIsEnabled) $
                    liftIO $ randomRIO (0, backoff) >>= threadDelay
                  if b < b'
                    then loop backoff' (nextBallotId b{ballotProposalId})
                    else loop backoff' b
              Right xs -> do
                  let x' = chooseValue d x xs
                  eth' <- retry retryTimeout $ command sendA acceptors d b x'
                  case eth' of
                      Left b@(BallotId{..}) -> do
                        paxosTrace $ "propose: command failed " ++ show b
                        when (not schedulerIsEnabled) $
                          liftIO $ randomRIO (0, backoff) >>= threadDelay
                        loop backoff' b{ballotProposalId}
                      Right _ -> do
                        paxosTrace $ "propose succeded: " ++ show d
                        return x'

protocol :: forall a n. SerializableDict a
         -> Int
         -> (n -> IO AcceptorStore)
         -> Protocol n a
protocol SerializableDict retryTimeout f =
    Protocol { prl_acceptor = acceptor (undefined :: a) f
             , prl_propose = propose retryTimeout
             , prl_releaseDecreesBelow = \sendA n d -> sendA n $ Trim d
             }

dictString :: SerializableDict String
dictString = SerializableDict

remotable ['protocol, 'dictString]

protocolClosure :: (Typeable a, Typeable n)
                => Static (SerializableDict a)
                -> Closure Int
                -> Closure (n -> IO AcceptorStore)
                -> Closure (Protocol n a)
protocolClosure sdict retryTimeoutClosure fp =
    staticClosure $(mkStatic 'protocol)
      `closureApply` staticClosure sdict
      `closureApply` retryTimeoutClosure
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
