-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

module HA.RecoverySupervisor.Tests ( tests ) where

import HA.RecoverySupervisor hiding (__remoteTable)
import HA.Replicator ( RGroup(..), retryRGroup )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables ( remoteTable )

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Internal.Types ( ProcessExitException )
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Network.Transport.Controlled ( Controlled, silenceBetween )
import Network.Transport.InMemory (createTransport)

import Control.Exception ( SomeException )
import qualified Control.Exception as E
import Control.Monad
  ( liftM2
  , void
  , replicateM_
  , replicateM
  , forM_
  , join
  )
#ifndef USE_MOCK_REPLICATOR
import Control.Monad (when)
import Data.Function (fix)
import Data.List (partition)
#endif
import Data.Int
import Data.IORef
import Network.Transport (Transport(..))
import Test.Framework
import Test.Transport
import Test.Tasty.HUnit
import System.Clock
import System.IO
import System.Random
import System.Timeout (timeout)


retryRG :: RGroup g => g st -> Process (Maybe a) -> Process a
retryRG g = retryRGroup g 1000000

pollingPeriod :: Int
pollingPeriod = 2000000

type ChanPorts a = (SendPort a, ReceivePort a)

data TestEvents = TestEvents
    { cStart :: ChanPorts ProcessId -- ^ RC has been started
    , cStop  :: ChanPorts ProcessId -- ^ RC has been stopped
    }

newCounters :: Process TestEvents
newCounters = liftM2 TestEvents newChan newChan

type RG = MC_RG RSState

rsSDict :: SerializableDict RSState
rsSDict = SerializableDict

remotable [ 'rsSDict ]

-- | Start RS environment, starts dummy RS that will notify about
-- it's events using "Counters".
testRS' :: TestEvents -- ^ Counters that is used in RC, see "Counters"
        -> Closure (Process RG) -- ^ RG
        -> Process ()
testRS' counters rg = do
  flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
    rGroup <- unClosure rg >>= id
    void $ spawnLocal $ recoverySupervisor rGroup $ dummyRC counters

  where

    dummyRC cnts = do
        say "started dummy RC"
        self <- getSelfPid
        sendChan (fst $ cStart cnts) self
        receiveWait []
      `catch` (\(_ :: ProcessExitException) -> do
                self <- getSelfPid
                say "dummy RC died"
                sendChan (fst $ cStop cnts) self
              )

tests :: AbstractTransport -> IO [TestTree]
tests abstractTransport = do
  (transport, controlled) <- mkControlledTransport abstractTransport
  putStrLn $ "Testing RecoverySupervisor ..."
  return
    [ testSuccess "rs-restart-if-process-dies" $ testSplit transport controlled 4 $
      \rc _ events _ cRGroup -> do
        exit rc "killed for testing"

        _ <- receiveChan $ snd $ cStart events
        _ <- receiveChan $ snd $ cStop events
        rGroup <- join $ unClosure cRGroup
        RSState (Just _) _ _<- retryRG rGroup $ getState rGroup
        return ()
#ifndef USE_MOCK_REPLICATOR
    , testSuccess "rs-restart-if-node-silent" $ testSplit transport controlled 4 $
      \rc ns events splitNet cRGroup -> do
        rGroup <- join $ unClosure cRGroup
        RSState (Just leader0) _ _ <- retryRG rGroup $ getState rGroup
        liftIO $ assertBool ("the leader is not the expected one"
                             ++ show (rc, leader0)
                            )
                            $ processNodeId rc == processNodeId leader0

        let ([leaderNode], rest) =
              partition ((processNodeId leader0 ==) . localNodeId) ns
        say $ "Isolating " ++ show (localNodeId leaderNode)
        splitNet [ [localNodeId leaderNode], map localNodeId rest ]

        -- Check that previous RC stops
        _ <- receiveChan $ snd $ cStop events

        -- Check that a new RC spawns
        _ <- fix $ \loop -> do
          rc' <- receiveChan $ snd $ cStart events -- XXX: Timeout ?
          when (processNodeId rc' == localNodeId leaderNode) loop

        -- Read new leader pid
        self <- getSelfPid
        _ <- liftIO $ forkProcess (head rest) $ do
               rGroup' <- join $ unClosure cRGroup
               retryRG rGroup' (getState rGroup') >>= usend self
        RSState (Just leader1) _ _<- expect
        -- Verify that we have new leader
        liftIO $ assertBool ("the leader is not new " ++
                             show (leader0, leader1)
                            )
                            $ leader0 /= leader1
    , testSuccess "rs-rc-killed-if-quorum-is-lost" $
       testSplit transport controlled 4 $ \rc ns events splitNet cRGroup -> do
        rGroup <- join $ unClosure cRGroup
        RSState (Just leader0) _ _ <- retryRG rGroup $ getState rGroup
        liftIO $ assertBool ("the leader is not the expected one"
                             ++ show (rc, leader0)
                            )
                            $ processNodeId rc == processNodeId leader0
        let ([leaderNode], rest) =
              partition (processNodeId leader0 ==) $ map localNodeId ns
        splitNet $ [leaderNode] : map (: []) rest
        _ <- receiveChan $ snd $ cStop events
        return ()
    , testSuccess "rs-split-in-majority" $ testSplit transport controlled 5
        $ \pid nodes events splitNet _ -> do
          let (as,bs) = splitAt 2 $ filter ((processNodeId pid /=) . localNodeId) nodes
          splitNet [ processNodeId pid : map localNodeId as
                   , map localNodeId bs
                   ]
          _ <- receiveTimeout (3*pollingPeriod) [] :: Process (Maybe ())
          mp <- receiveChanTimeout 0 $ snd $ cStop events
          case mp of
            Nothing -> return ()
            -- If the RC was killed, it should respawn quickly.
            Just p | p == pid -> do
              p' <- receiveChan $ snd $ cStart events
              True <- return $ elem (processNodeId p')
                             $ processNodeId pid : map localNodeId as
              return ()
            _ -> error "unexpected event from the RC"
    , testSuccess "rs-split-in-minority" $ testSplit transport controlled 5 $ \pid nodes events splitNet cRGroup -> do
        let (as,bs) = splitAt 3 $ filter ((processNodeId pid /=) . localNodeId) nodes
        splitNet [ map localNodeId as
                 , processNodeId pid : map localNodeId bs
                 ]

        -- wait that RS eventually stop
        _ <- fix $ \loop -> do
               p <- receiveChan $ snd $ cStop events
               when (p /= pid) loop
        -- wait that new RS eventually starts
        _ <- receiveChan $ snd $ cStart events
        self <- getSelfPid
        _ <- liftIO $ forkProcess (head as) $ do
               rGroup' <- join $ unClosure cRGroup
               retryRG rGroup' (getState rGroup') >>= usend self
        RSState (Just _) _ _<- expect
        return ()
    , testSuccess "rs-split-in-half"  $ testSplit transport controlled 5 $ \pid nodes events splitNet _ -> do
        let [a1,a2,a3,a4,a5] = map localNodeId nodes
        splitNet [[a1,a2], [a3,a4], [a5]]
        -- wait that RS eventually stop
        _ <- fix $ \loop -> do
               p <- receiveChan $ snd $ cStop events
               when (p /= pid) loop
        _ <- receiveTimeout (3*pollingPeriod) [] :: Process (Maybe ())
        mp <- receiveChanTimeout 0 $ snd $ cStart events
        case mp of
          Nothing -> return ()
          -- If the RC was killed, it should stop quickly.
          Just p' -> do
            p'' <- receiveChan $ snd $ cStop events
            True <- return $ p' == p''
            return ()
        return ()
#endif
    , timerTests transport
    ]

testSplit :: Transport
          -> Controlled
          -- ^ Transport and controller object.
          -> Int
          -- ^ Number of nodes to create.
          -> (ProcessId
               -- ^ Pd of the leader.
               -> [LocalNode]
               -- ^ List of replica nodes.
               -> TestEvents
               -- ^ Channel with RS events.
               -> ([[NodeId]] -> Process ())
               -- ^ Callback that splits network between nodes in groups.
               -> Closure (Process (MC_RG RSState))
               -- ^ Group handle.
               -> Process ())
          -> IO ()
testSplit transport t amountOfReplicas action =
    runTest' (amountOfReplicas + 1) 10 transport $ \ns -> do
      self <- getSelfPid
      events    <- newCounters
      let nids = map localNodeId ns
      bracket (do
                 cRGroup <- newRGroup $(mkStatic 'rsSDict) "rstest" 20
                                      pollingPeriod nids
                                      (RSState Nothing 0 pollingPeriod)
                 rGroup <- join $ unClosure cRGroup
                 return (cRGroup, rGroup)
              )
              (\(_, rGroup) -> forM_ nids $ killReplica rGroup)
             $ \(cRGroup, rGroup) -> do

        forM_ ns $ \n -> liftIO $ forkProcess n $ do
          testRS' events cRGroup
          usend self ((), ())
        replicateM_ amountOfReplicas (expect :: Process ((), ()))

        let doSplit nds =
              (if Scheduler.schedulerIsEnabled
                 then Scheduler.addFailures . concat .
                      map (\(a, b) -> [((a, b), 1.0), ((b, a), 1.0)])
                 else liftIO . sequence_ .
                      map (\(a, b) -> silenceBetween t (nodeAddress a)
                                                    (nodeAddress b)
                          )
              )
              [ (a, b) | a <- concat nds, x <- nds, notElem a x, b <- x ]

        pid0 <- receiveChan $ snd $ cStart events
        Nothing <- receiveChanTimeout 0 $ snd $ cStop events
        RSState (Just _) _ _ <- retryRG rGroup $ getState rGroup
        action pid0 ns events doSplit cRGroup
        -- TODO: implement closing RGroups and call it here.

timerTests :: Transport -> TestTree
timerTests transport = testGroup "RS Timer"
  [ testSuccess "rs-timer-run-after-timeout" $ testTimerRunAfterTimeout transport
  , testSuccess "rs-timer-cancelled" $ testTimerCancelled transport
  -- XXX: if asynchronous exception will arrive to the thread that calls cancel
  -- it's possible for the timer thread to lock forever.
  -- See: https://app.asana.com/0/12314345447678/43375013903903
  -- , testSuccess "rs-timer-should-survive-exceptions" $ testTimerExceptionLiveness transport
  , testSuccess "rs-timer-concurrent-cancel" $ testTimerConcurrentCancel transport
  ]

data TimerData = TimerData { firedAt :: IORef Int64 }

testTimerRunAfterTimeout :: Transport -> Assertion
testTimerRunAfterTimeout transport = do
  td <- TimerData <$> newIORef 0
  runTest transport $ do
    forM_ [100,1000,10000] $ \delay -> do
      tf <- liftIO $ timeSpecToMicro <$> getTime Monotonic
      timer <- newTimer delay $ liftIO $ writeIORef (firedAt td) . timeSpecToMicro =<< getTime Monotonic
      _     <- receiveTimeout (delay*2) []
      liftIO . assertBool "timeout callback should fire" . not =<< cancel timer
      tf' <-   liftIO $ readIORef (firedAt td)
      liftIO $ assertBool ("timeout should fire after " ++ show delay ++ "us")
                          (tf'-tf >= fromIntegral delay)

testTimerCancelled :: Transport -> Assertion
testTimerCancelled transport = do
  td <- TimerData <$> newIORef 0
  runTest transport $ do
    forM_ [100,1000,10000] $ \delay -> do
      tf <- liftIO $ timeSpecToMicro <$> getTime Monotonic
      timer <- newTimer delay $ liftIO $ writeIORef (firedAt td) . timeSpecToMicro =<< getTime Monotonic
      _     <- receiveTimeout (delay `div` 2) []
      cancelled <- cancel timer
      if cancelled
         then liftIO $ assertEqual "action should not happen" 0 =<< readIORef (firedAt td)
         else liftIO $ do
           tf' <- timeSpecToMicro <$> getTime Monotonic
           assertBool "we missed timeout" (tf'-tf >= fromIntegral delay)
           writeIORef (firedAt td) 0

testTimerConcurrentCancel :: Transport -> Assertion
testTimerConcurrentCancel transport = do
  td <- TimerData <$> newIORef 0
  runTest transport $ do
    let delay = 10000
    self <- getSelfPid
    tf <- liftIO $ timeSpecToMicro <$> getTime Monotonic
    timer <- newTimer delay $ liftIO $ writeIORef (firedAt td) . timeSpecToMicro =<< getTime Monotonic
    replicateM_ 5 $ spawnLocal $ cancel timer >>= usend self
    (r:esults) <- replicateM 5 expect
    liftIO $ assertBool "all results are equal" $ all (==r) esults
    if r
       then liftIO $ assertEqual "action should not happen" 0 =<< readIORef (firedAt td)
       else liftIO $ do
         tf' <- timeSpecToMicro <$> getTime Monotonic
         assertBool "we missed timeout"
                    (tf'-tf >= fromIntegral delay)

runTest :: Transport -> Process () -> IO ()
runTest tr action = runTest' 1 200 tr $ const action

runTest' :: Int -> Int -> Transport -> ([LocalNode] -> Process ()) -> IO ()
runTest' numNodes numReps tr action
    | Scheduler.schedulerIsEnabled = do
        s <- randomIO
        -- TODO: Fix leaks in n-t-inmemory and use the same transport for all
        -- tests, maybe.
        forM_ [1..numReps] $ \i ->  withTmpDirectory $
          E.bracket createTransport closeTransport $ \tr' ->
          let s' = s + i - 1 in do
            m <- timeout (7 * 60 * 1000000) $
              Scheduler.withScheduler s' 1000 numNodes tr' rt action
            maybe (error "Timeout") return m
          `E.onException`
            liftIO (hPutStrLn stderr $ "Failed with seed: " ++ show s')
    | otherwise =
        withTmpDirectory $ withLocalNodes numNodes tr rt $
          \(n : ns) -> runProcess n (action ns)
  where
    rt = Scheduler.__remoteTable $ __remoteTable remoteTable
