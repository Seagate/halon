{-# LANGUAGE TemplateHaskell #-}
module Test (tests) where

import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Consensus.Paxos.Messages
import Control.Distributed.Process.Consensus.Paxos.Types
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos

import Test.Framework

import Control.Distributed.Process hiding (try)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Scheduler
    ( withScheduler, __remoteTable )
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Network.Transport (Transport)
import Network.Transport.TCP

import System.Posix.Temp (mkdtemp)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Applicative ((<$>))
import Control.Monad.Writer


remoteTables :: RemoteTable
remoteTables =
  Control.Distributed.Process.Consensus.__remoteTable $
  Control.Distributed.Process.Scheduler.__remoteTable $
  BasicPaxos.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

setup :: Transport -> ([ProcessId] -> Process ()) -> IO ()
setup transport action = do
    node0 <- newLocalNode transport remoteTables
    done <- newEmptyMVar
    tmpdir <- mkdtemp "/tmp/tmp."

    putChar '\n'
    runProcess node0 $ withScheduler [] 1 $ do
         α <- spawnLocal $ acceptor (undefined :: Int) (const tmpdir) ""
         action [α]
         liftIO $ threadDelay 1000000
         liftIO $ putMVar done ()
    failure <- isEmptyMVar done
    when failure $ fail "Test failed."

proposeWrapper :: [ProcessId] -> DecreeId -> Int -> Process Bool
proposeWrapper αs d x = (x ==) <$> runPropose (BasicPaxos.propose αs d x)

tests :: IO [Test]
tests = do
    Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters

    return
      [ testSuccess "single-decree" $ setup transport $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
      , testSuccess "two-decree"    $ setup transport $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< proposeWrapper them (DecreeId 0 1) 10
      , testSuccess "same-decree-same-value" $ setup transport $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< proposeWrapper them (DecreeId 0 0) 42
      , testSuccess "same-decree-different-value" $ setup transport $ \them -> do
            assert =<< proposeWrapper them (DecreeId 0 0) 42
            assert =<< not <$> proposeWrapper them (DecreeId 0 0) 10

        -- Test that the Nack sent back is always higher than the Prepare
        -- request that was sent.
      , testSuccess "nack-prepare" $ setup transport $ \them -> do
            self <- getSelfPid
            let first  = BallotId 0 self
            let second = BallotId 1 self
            forM_ them $ \α -> send α $ Prepare (DecreeId 0 0) second self
            forM_ them $ \α -> send α $ Prepare (DecreeId 0 0) first self
            nacks :: [Nack] <- forM them $ \_ -> expect
            assert $ all (\nack -> first < ballot nack) nacks

        -- Test that the ballot number from a proposer always matches the
        -- ProcessId of the proposer.
      , testSuccess "processid-proposer" $ setup transport $ \them -> do
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
      ]
