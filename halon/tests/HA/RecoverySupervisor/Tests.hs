-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.RecoverySupervisor.Tests ( tests ) where

import HA.Process
import HA.RecoverySupervisor
  ( recoverySupervisor
  , RSState(..)
  , pollingPeriod
  )
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables ( remoteTable )

import Control.Distributed.Process
  ( Process
  , spawnLocal
  , getSelfPid
  , liftIO
  , catch
  , receiveWait
  , receiveTimeout
  , ProcessId
  , exit
  , unClosure
  )
import Control.Distributed.Process.Closure ( mkStatic, remotable )
#ifndef USE_MOCK_REPLICATOR
import Control.Distributed.Process ( spawn )
import Control.Distributed.Process.Closure ( mkClosure )
import Control.Distributed.Static ( closureApply )
#endif
import Control.Distributed.Process.Internal.Types
  ( ProcessExitException
  , localNodeId
  )
import Control.Distributed.Process.Node ( newLocalNode, closeLocalNode )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Control.Concurrent
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , threadDelay
  )
import Control.Exception ( SomeException )
import Control.Monad ( liftM3, void, replicateM_, replicateM, forM_ )
import Data.IORef ( newIORef, atomicModifyIORef, IORef, readIORef, writeIORef )
import Network.Transport (Transport)
import System.IO.Unsafe ( unsafePerformIO )
import Test.Framework

data TestCounters = TestCounters
    { cStart :: IORef Int -- ^ the amount of times RC has been started
    , cStop :: IORef Int -- ^ the amount of times RC has been stopped
    , cRC :: IORef (Maybe ProcessId) -- ^ the pid of the last started RC
    }

newCounters :: IO TestCounters
newCounters = liftM3 TestCounters (newIORef 0) (newIORef 0) (newIORef Nothing)

type RG = MC_RG RSState

testRS' :: MVar () -> TestCounters -> RG -> Process ()
testRS' mdone counters rGroup = do
  flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
    void $ spawnLocal $ recoverySupervisor rGroup
                             $ spawnLocal (dummyRC counters)
    liftIO $ putMVar mdone ()

  where

    addCounter r i = liftIO $ atomicModifyIORef r $ \s -> (s+i,())

    dummyRC cnts = do
        self <- getSelfPid
        liftIO $ writeIORef (cRC cnts) $ Just self
        addCounter (cStart cnts) 1
        receiveWait []
      `catch` (\(_ :: ProcessExitException) -> addCounter (cStop cnts) 1)

rsSDict :: SerializableDict RSState
rsSDict = SerializableDict

remotable [ 'rsSDict ]

tests :: Bool -> Transport -> IO [TestTree]
tests oneNode transport = do
  putStrLn $ "Testing RecoverySupervisor " ++
              if oneNode then "with one node..."
               else "with multiple nodes..."
  return
    [ testSuccess "leaderSurvived" $ rsTest transport oneNode $ \counters rGroup -> do
        leader0 <- retryTest $ do
            1 <- readRef $ cStart counters
            0 <- readRef $ cStop counters
            RSState (Just leader0) _ <- getState rGroup
            return leader0

        leader1 <- retryTest $ do
            RSState (Just leader1) _c1 <- getState rGroup
            1 <- readRef $ cStart counters
            0 <- readRef $ cStop counters
            return leader1

        assert $ leader0 == leader1 -- && c1 == 1 + div pollingPeriod updatePeriod

    , testSuccess "newLeader" $ rsTest transport oneNode $ \counters rGroup -> do
        _leader0 <- retryTest $ do
            1 <- readRef $ cStart counters
            0 <- readRef $ cStop counters
            RSState (Just leader0) _ <- getState rGroup
            return leader0

        Just rc <- readRef (cRC counters)
        exit rc "killed for testing"

        retryTest $ do
            RSState (Just _) _c2 <- getState rGroup
            2 <- readRef $ cStart counters
            1 <- readRef $ cStop counters
            return ()
    ]

rsTest :: Transport -> Bool -> (TestCounters -> MC_RG RSState -> Process ()) -> IO ()
rsTest transport oneNode action = withTmpDirectory $ do
  let amountOfReplicas = 2
  ns@(n1:_) <-
    replicateM amountOfReplicas
        $ newLocalNode transport
        $ __remoteTable remoteTable
  mTestDone <- newEmptyMVar
  tryRunProcess n1 $ do
      let nids = map localNodeId $ if oneNode
                   then replicate amountOfReplicas n1
                   else ns
      cRGroup <- newRGroup $(mkStatic 'rsSDict) nids (RSState Nothing 0)

      rGroup   <- unClosure cRGroup >>= id
      counters <- liftIO newCounters
      mdone    <- liftIO newEmptyMVar

      forM_ nids $ const $ spawnLocal $ testRS' mdone counters rGroup
      replicateM_ amountOfReplicas $ liftIO $ takeMVar mdone
      action counters rGroup
      liftIO $ putMVar mTestDone ()

  takeMVar mTestDone
  -- Exit after transport stops being used.
  -- TODO: fix closeTransport and call it here (see ticket #211).
  -- TODO: implement closing RGroups and call it here.
  threadDelay 2000000
  -- TODO: Uncomment the following line when terminateLocalProcesses
  -- does not block indefinitely.
  -- mapM_ (flip terminateLocalProcesses (Just pollingPeriod)) ns
  mapM_ closeLocalNode ns

retryTest :: Process a -> Process a
retryTest = retryTest' 5 pollingPeriod
  where
    retryTest' :: Int -> Int -> Process a -> Process a
    retryTest' n t p | n>1 =
       do void $ receiveTimeout t []
          catch p $ \e -> const (retryTest' (n-1) t p) (e :: SomeException)
    retryTest' _ _ p = p

readRef :: IORef a -> Process a
readRef = liftIO . readIORef
