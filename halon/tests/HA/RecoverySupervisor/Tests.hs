-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

module HA.RecoverySupervisor.Tests ( tests, disconnectionTests ) where

import HA.RecoverySupervisor
import HA.Replicator ( RGroup(..) )
import RemoteTables ( remoteTable )

import Control.Distributed.Process hiding (bracket, catch)
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
  , forM_
  , join
  , when
  )
import Control.Monad.Catch (bracket, catch)
import Data.Function (fix)
import Data.List (partition)
import Data.Proxy
import Data.Typeable
import Network.Transport (Transport(..))
import Test.Framework
import Test.Transport
import Test.Tasty.HUnit
import System.IO
import System.Random
import System.Timeout (timeout)


pollingPeriod :: Int
pollingPeriod = 2000000

type ChanPorts a = (SendPort a, ReceivePort a)

data TestEvents = TestEvents
    { cStart :: ChanPorts ProcessId -- ^ RC has been started
    , cStop  :: ChanPorts ProcessId -- ^ RC has been stopped
    }

newCounters :: Process TestEvents
newCounters = liftM2 TestEvents newChan newChan

rsSDict :: SerializableDict ()
rsSDict = SerializableDict

remotable [ 'rsSDict ]

-- | Start RS environment, starts dummy RS that will notify about
-- it's events using "Counters".
testRS' :: (Typeable g, RGroup g)
        => TestEvents -- ^ Counters that is used in RC, see "Counters"
        -> Closure (Process (g ())) -- ^ RG
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

tests :: forall g. (Typeable g, RGroup g)
      => AbstractTransport -> Proxy g -> IO [TestTree]
tests abstractTransport _ = do
  (transport, controlled) <- mkControlledTransport abstractTransport
  return
    [ testSuccess "rs-restart-if-process-dies" $ testSplit transport controlled 4 $
      \rc _ events _ (_ :: Closure (Process (g ()))) -> do
        exit rc "killed for testing"

        _ <- receiveChan $ snd $ cStop events
        _ <- receiveChan $ snd $ cStart events
        return ()
    ]

disconnectionTests :: forall g. (Typeable g, RGroup g)
                   => AbstractTransport -> Proxy g -> IO [TestTree]
disconnectionTests abstractTransport _ = do
  (transport, controlled) <- mkControlledTransport abstractTransport
  return [ testSuccess "rs-restart-if-node-silent" $ testSplit transport controlled 4 $
      \rc ns events splitNet cRGroup -> do
        rGroup :: g () <- join $ unClosure cRGroup
        leader0 <- fix $ \loop -> getLeaderReplica rGroup >>=
                     maybe (receiveTimeout 500000 [] >> loop) return
        liftIO $ assertBool ("the leader is not the expected one"
                             ++ show (rc, leader0)
                            )
                            $ processNodeId rc == leader0
        say "Passed first assertion"

        -- read all NodeIds in the mailbox.
        fix $ \loop -> receiveTimeout 0 [ match $ \nid -> return (nid :: NodeId) ]
                       >>= maybe (return ()) (const loop)

        let ([leaderNode], rest) =
              partition ((leader0 ==) . localNodeId) ns
        say $ "Isolating " ++ show (localNodeId leaderNode)
        splitNet [ [localNodeId leaderNode], map localNodeId rest ]

        say "Check that previous RC stops."
        _ <- receiveChan $ snd $ cStop events

        say "Check that a new RC spawns."
        _ <- fix $ \loop -> do
          rc' <- receiveChan $ snd $ cStart events -- XXX: Timeout ?
          when (processNodeId rc' == localNodeId leaderNode) loop

        say "Read new leader nid."
        leader1 <- fix $ \loop -> getLeaderReplica rGroup >>=
                     maybe (receiveTimeout 500000 [] >> loop) return

        say "Verify that we have a new leader."
        liftIO $ assertBool ("the leader is not new " ++
                             show (leader0, leader1)
                            )
                            $ leader0 /= leader1
    , testSuccess "rs-rc-killed-if-quorum-is-lost" $
       testSplit transport controlled 4 $ \rc ns events splitNet cRGroup -> do
        rGroup :: g () <- join $ unClosure cRGroup
        leader0 <- fix $ \loop -> getLeaderReplica rGroup >>=
                     maybe (receiveTimeout 500000 [] >> loop) return
        liftIO $ assertBool ("the leader is not the expected one"
                             ++ show (rc, leader0)
                            )
                            $ processNodeId rc == leader0
        let ([leaderNode], rest) =
              partition (leader0 ==) $ map localNodeId ns
        splitNet $ [leaderNode] : map (: []) rest
        _ <- receiveChan $ snd $ cStop events
        return ()
    , testSuccess "rs-split-in-majority" $ testSplit transport controlled 5
        $ \pid nodes events splitNet (_ :: Closure (Process (g ()))) -> do
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
            _ = cRGroup :: Closure (Process (g ()))
        splitNet [ map localNodeId as
                 , processNodeId pid : map localNodeId bs
                 ]

        say "Wait that RS eventually stop."
        _ <- fix $ \loop -> do
               p <- receiveChan $ snd $ cStop events
               when (p /= pid) loop
        say "Wait that new RS eventually starts."
        _ <- receiveChan $ snd $ cStart events
        return ()
    , testSuccess "rs-split-in-half"  $ testSplit transport controlled 5 $
        \pid nodes events splitNet (_ :: Closure (Process (g ()))) -> do
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
    ]

testSplit :: (Typeable g, RGroup g)
          => Transport
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
               -> Closure (Process (g ()))
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
                                      pollingPeriod 4000000 nids
                                      ()
                 rGroup <- join $ unClosure cRGroup
                 return (cRGroup, rGroup)
              )
              (\(_, rGroup) -> forM_ nids $ killReplica rGroup)
             $ \(cRGroup, _) -> do

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
        action pid0 ns events doSplit cRGroup
        -- TODO: implement closing RGroups and call it here.

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
