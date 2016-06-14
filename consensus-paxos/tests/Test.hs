{-# LANGUAGE TemplateHaskell #-}
module Test (tests) where

import Prelude hiding ((<$>))
import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Consensus.Paxos.Messages
import Control.Distributed.Process.Consensus.Paxos.Types
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos

import Test.Framework

import Control.Distributed.Process hiding (try)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Network.Transport (Transport)
import Network.Transport.TCP

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Applicative ((<$>))
import Control.Monad.Writer
import Data.IORef
import qualified Data.Map as Map

remoteTables :: RemoteTable
remoteTables =
  Control.Distributed.Process.Consensus.__remoteTable $
  BasicPaxos.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

spawnAcceptor :: Process ProcessId
spawnAcceptor = do
    mref <- liftIO $ newIORef Map.empty
    vref <- liftIO $ newIORef Nothing
    spawnLocal $ do
      self <- getSelfPid
      acceptor usend
        (undefined :: Int) initialDecreeId
        (const $ return AcceptorStore
                      { storeInsert = (>>) . liftIO .
                          modifyIORef mref . flip (foldr (uncurry Map.insert))
                      , storeLookup = \d ->
                          (>>=) $ liftIO $ Map.lookup d <$> readIORef mref
                      , storePut = (>>) . liftIO . writeIORef vref . Just
                      , storeGet = (>>=) $ liftIO $ readIORef vref
                      , storeTrim = const $ return ()
                      , storeList =
                          (>>=) $ liftIO $ Map.assocs <$> readIORef mref
                      , storeMap = (>>=) $ liftIO $ readIORef mref
                      , storeClose = return ()
                      }
        )
        self

setup :: Transport -> Int -> ([ProcessId] -> Process ()) -> IO ()
setup transport numAcceptors action = do
    node0 <- newLocalNode transport remoteTables
    done <- newEmptyMVar

    putChar '\n'
    runProcess node0 $ do
         αs <- replicateM numAcceptors spawnAcceptor
         action αs
         forM_ αs monitor
         forM_ αs (flip kill "test finished")
         forM_ αs $ const (expect :: Process ProcessMonitorNotification)
         liftIO $ threadDelay 1000000
         liftIO $ putMVar done ()
    closeLocalNode node0
    failure <- isEmptyMVar done
    when failure $ fail "Test failed."

proposeWrapper :: [ProcessId] -> DecreeId -> Int -> Process Bool
proposeWrapper αs d x = (x ==) <$>
    runPropose (BasicPaxos.propose 1000000 send αs d x)

tests :: IO TestTree
tests = do
    Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters

    return $ testGroup "consensus-paxos"
      [ testSuccess "single-decree" $ setup transport 1 $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
      , testSuccess "two-decree"    $ setup transport 1 $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< proposeWrapper them (DecreeId 0 1) 10
      , testSuccess "same-decree-same-value" $ setup transport 1 $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< proposeWrapper them (DecreeId 0 0) 42
      , testSuccess "same-decree-different-value" $ setup transport 1 $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< not <$> proposeWrapper them (DecreeId 0 0) 10

        -- Test that the Nack sent back is always higher than the Prepare
        -- request that was sent.
      , testSuccess "nack-prepare" $ setup transport 1 $ \them -> do
            self <- getSelfPid
            let first  = BallotId 0 self
            let second = BallotId 1 self
            forM_ them $ \α -> send α $ Prepare (DecreeId 0 0) second self
            forM_ them $ \α -> send α $ Prepare (DecreeId 0 0) first self
            nacks :: [Nack] <- forM them $ \_ -> expect
            assert $ all (\nack -> first < ballot nack) nacks

        -- Test that the ballot number from a proposer always matches the
        -- ProcessId of the proposer.
      , testSuccess "processid-proposer" $ setup transport 1 $ \them -> do
            self <- getSelfPid
            node <- getSelfNode
            let bogusBallot = BallotId 100 (nullProcessId node)

            -- Proxy acceptors that check well formation of messages sent by
            -- proposer.
            them' <- forM them $ \α -> spawnLocal $ forever $ do
                let check b = ballotProcessId b == self
                success <- receiveWait
                    [ match $ \msg@(Prepare (DecreeId 0 0) b _) -> do
                          send α msg
                          return $ check b
                    , match $ \msg@(Syn _ b _ (_ :: Int)) -> do
                          send α msg
                          return $ check b ]
                unless success $ do
                    say "Intercepted bad message."
                    liftIO $ threadDelay 100000
                    exit self ()

            forM_ them $ \α -> send α $ Prepare (DecreeId 0 0) bogusBallot self
            assert =<< proposeWrapper them' (DecreeId 0 0) 42

        -- Test queries.
      , testSuccess "query" $ setup transport 2 $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< proposeWrapper them (DecreeId 0 1) 10
            res <- BasicPaxos.query send them (DecreeId 0 0)
            say (show res)
            assert (res == [(DecreeId 0 0, 42), (DecreeId 0 1, (10 :: Int))])

         -- Test that acceptors know about decrees after synchronization.
      , testSuccess "sync" $ setup transport 1 $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< proposeWrapper them (DecreeId 0 1) 10
            αs <- replicateM 3 spawnAcceptor
            say "sync ..."
            BasicPaxos.sync usend (αs ++ them)
            say "Testing result of sync ..."
            res <- BasicPaxos.query send αs (DecreeId 0 0)
            say (show res)
            assert (res == [(DecreeId 0 0, 42), (DecreeId 0 1, (10 :: Int))])

         -- Test that sync succeeds when there is nothing to update.
      , testSuccess "sync-up-to-date" $ setup transport 2 $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< proposeWrapper them (DecreeId 0 1) 10
            say "sync ..."
            BasicPaxos.sync usend them
            say "Checking result of sync ..."
            res <- BasicPaxos.query send them (DecreeId 0 0)
            say (show res)
            assert (res == [(DecreeId 0 0, 42), (DecreeId 0 1, (10 :: Int))])
       ]
