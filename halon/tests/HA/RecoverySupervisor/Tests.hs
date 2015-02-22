-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

module HA.RecoverySupervisor.Tests ( tests ) where

import HA.Process
import HA.RecoverySupervisor
  ( recoverySupervisor
  , RSState(..)
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
  , ProcessId
  , exit
  , unClosure
  )
import Control.Distributed.Process.Closure ( mkStatic, remotable )
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
  , tryTakeMVar
  , threadDelay
  )
import Control.Exception ( SomeException )
import Control.Monad ( liftM3, void, replicateM_, replicateM, forM_ )
import Network.Transport (Transport)
import Test.Framework

data TestCounters = TestCounters
    { cStart :: MVar ()        -- ^ RC has been started
    , cStop  :: MVar ()        -- ^ RC has been stopped
    , cRC    :: MVar ProcessId -- ^ RC pid
    }

newCounters :: IO TestCounters
newCounters = liftM3 TestCounters newEmptyMVar newEmptyMVar newEmptyMVar

type RG = MC_RG RSState

testRS' :: MVar () -> TestCounters -> RG -> Process ()
testRS' mdone counters rGroup = do
  flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
    void $ spawnLocal $ recoverySupervisor rGroup 1000000
                             $ spawnLocal (dummyRC counters)
    liftIO $ putMVar mdone ()

  where

    dummyRC cnts = do
        self <- getSelfPid
        liftIO $ do
          putMVar (cRC cnts) self
          putMVar (cStart cnts) ()
        receiveWait []
      `catch` (\(_ :: ProcessExitException) -> liftIO $ putMVar (cStop cnts) ())

rsSDict :: SerializableDict RSState
rsSDict = SerializableDict

remotable [ 'rsSDict ]

tests :: Bool -> Transport -> IO [TestTree]
tests oneNode transport = do
  putStrLn $ "Testing RecoverySupervisor " ++
              if oneNode then "with one node..."
               else "with multiple nodes..."
  return
    [ testSuccess "newLeader" $ rsTest transport oneNode $ \counters rGroup -> do
        _leader0 <- do
            liftIO $ do
              takeMVar $ cStart counters
              Nothing <- tryTakeMVar $ cStop counters
              return ()
            RSState (Just leader0) _ <- getState rGroup
            return leader0

        rc <- liftIO $ takeMVar $ cRC counters
        exit rc "killed for testing"

        liftIO $ do
          takeMVar $ cStart counters
          takeMVar $ cStop counters
        RSState (Just _) _ <- getState rGroup
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
      cRGroup <- newRGroup $(mkStatic 'rsSDict) 20 nids (RSState Nothing 0)

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
