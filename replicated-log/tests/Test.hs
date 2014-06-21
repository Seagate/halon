-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
module Test (Pass(..), tests) where

import Test.Framework

import Control.Distributed.Process.Consensus
    ( DecreeId(..), runPropose, __remoteTable )
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log
    ( TypeableDict(..), sdictValue, updateHandle )
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import qualified Control.Distributed.Log.Policy as Policy
import Control.Distributed.Log.Policy -- XXX workaround for distributed-process TH bug.

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler
    ( withScheduler, __remoteTable )
import Control.Distributed.Process.Internal.Types (nodeAddress)
import Control.Distributed.Static
import Data.Rank1Dynamic
import Network.Transport.TCP

import System.Directory
import System.IO
import System.FilePath ((</>))
import Control.Monad (forM_, replicateM, when, void)
import Control.Applicative ((<$>))
import Data.Typeable (Typeable)
import Data.Binary (encode)

import Prelude hiding (read)
import qualified Prelude

newtype State = State { unState :: Int }
    deriving (Typeable)

increment :: State -> Process State
increment (State x) = do say "Increment."; return $ State $ x + 1

incrementCP :: CP State State
incrementCP = staticClosure incrementStatic
  where
    incrementStatic :: Static (State -> Process State)
    incrementStatic = staticLabel "Test.increment"

read :: State -> Process Int
read = return . unState

readCP :: CP State Int
readCP = staticClosure readStatic
  where
    readStatic :: Static (State -> Process Int)
    readStatic = staticLabel "Test.read"

dictInt :: SerializableDict Int
dictInt = SerializableDict

dictState :: TypeableDict State
dictState = TypeableDict

dictNodeId :: SerializableDict NodeId
dictNodeId = SerializableDict

testLog :: State.Log State
testLog = State.log $ return $ State 0

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

remotable [ 'dictInt, 'dictState, 'dictNodeId, 'testLog, 'filepath ]

sdictInt :: Static (SerializableDict Int)
sdictInt = $(mkStatic 'dictInt)

sdictState :: Static (TypeableDict State)
sdictState = $(mkStatic 'dictState)

sdictNodeId :: Static (SerializableDict NodeId)
sdictNodeId = $(mkStatic 'dictNodeId)

remoteTables :: RemoteTable
remoteTables =
  Test.__remoteTable $
  registerStatic "Test.increment" (toDynamic increment) $
  registerStatic "Test.read" (toDynamic read) $
  Control.Distributed.Process.Consensus.__remoteTable $
  Control.Distributed.Process.Scheduler.__remoteTable $
  BasicPaxos.__remoteTable $
  Log.__remoteTable $
  Log.__remoteTableDecl $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

proposeWrapper :: [ProcessId] -> DecreeId -> Int -> Process Bool
proposeWrapper αs d x = (x ==) <$> runPropose (BasicPaxos.propose αs d x)

data Pass = FirstPass | SecondPass
          deriving (Eq, Ord, Read, Show)

tests :: [String] -> IO TestTree
tests args = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
    putStrLn "Transport created."

    let leaseRenewalMargin = 1000000
        setup :: Int                      -- ^ Number of nodes to spawn group on.
              -> (Log.Handle (Command State) -> State.CommandPort State -> Process ())
              -> IO ()
        setup num action = tryWithTimeout transport remoteTables defaultTimeout $ do
            node0 <- getSelfNode
            nodes <- replicateM (num - 1) $ liftIO $ newLocalNode transport remoteTables
            setup' (node0 : map localNodeId nodes) action
        setup' nodes action =
            withScheduler [] 1 $ do
                say $ "Spawning group."
                h <- Log.new $(mkStatic 'State.commandEqDict)
                             ($(mkStatic 'State.commandSerializableDict)
                                `staticApply` sdictState)
                             ($(mkClosure 'filepath) "replicas")
                             (BasicPaxos.protocolClosure
                                 (sdictValue
                                     ($(mkStatic 'State.commandSerializableDict)
                                        `staticApply` sdictState))
                                 ($(mkClosure 'filepath) "acceptors"))
                             (staticClosure $(mkStatic 'testLog))
                             3000000
                             leaseRenewalMargin
                             nodes
                port <- State.newPort h
                action h port

    let ut = testGroup "ut"
          [ testSuccess "single-command" . withTmpDirectory $ setup 1 $ \_ port -> do
                State.update port incrementCP
                assert . (== 1) =<< State.select sdictInt port readCP

          , testSuccess "two-command" . withTmpDirectory    $ setup 1 $ \_ port -> do
                State.update port incrementCP
                State.update port incrementCP
                assert . (== 2) =<< State.select sdictInt port readCP

          , testSuccess "clone" . withTmpDirectory          $ setup 1 $ \h _ -> do
                self <- getSelfPid
                rh <- Log.remoteHandle h
                send self rh
                rh' <- expect
                h' <- Log.clone rh'
                port <- State.newPort h'
                State.update port incrementCP
                State.update port incrementCP
                assert . (== 2) =<< State.select sdictInt port readCP

          -- , testSuccess "duplicate-command" $ setup $ \h port -> do
          --       port' <- State.newPort h
          --       State.update port  incrementCP
          --       State.update port  incrementCP
          --       State.update port' incrementCP
          --       assert . (== 2) =<< State.select sdictInt port readCP

          , testSuccess "addReplica-start-new-replica" . withTmpDirectory $ setup 1 $ \h port -> do
                self <- getSelfPid
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ registerInterceptor $ \string -> case string of
                    "New replica started in legislature://1" -> send self ()
                    _ -> return ()

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    void $ Log.addReplica h
                             (staticClosure $(mkStatic 'Policy.meToo)) here
                             leaseRenewalMargin
                expect

          , testSuccess "addReplica-new-replica-old-decrees" . withTmpDirectory $ setup 1 $ \h port -> do
                self <- getSelfPid
                let interceptor "Increment." = send self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ registerInterceptor $ interceptor

                State.update port $ incrementCP
                () <- expect
                say "Existing replica incremented."

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    void $ Log.addReplica h
                             (staticClosure $(mkStatic 'Policy.meToo))
                             here leaseRenewalMargin
                () <- expect
                say "New replica incremented."

          , testSuccess "addReplica-new-replica-new-decrees" . withTmpDirectory $ setup 1 $ \h port -> do
                self <- getSelfPid
                let interceptor "Increment." = send self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ registerInterceptor $ interceptor

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    void $ Log.addReplica h
                             (staticClosure $(mkStatic 'Policy.meToo)) here
                             leaseRenewalMargin

                State.update port $ incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."

          , testSuccess "update-handle" . withTmpDirectory $ do
              n <- newLocalNode transport remoteTables
              tryWithTimeout transport remoteTables defaultTimeout
                  $ setup' [localNodeId n] $ \h port -> do
                self <- getSelfPid
                let interceptor "Increment." = send self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ do
                    registerInterceptor $ interceptor
                    here <- getSelfNode
                    void $ Log.addReplica h
                             (staticClosure $(mkStatic 'Policy.meToo)) here
                             leaseRenewalMargin

                here <- getSelfNode
                ρ <- Log.addReplica h (staticClosure $(mkStatic 'Policy.meToo))
                       here leaseRenewalMargin
                updateHandle h ρ

                liftIO $ closeLocalNode n
                State.update port $ incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."

          , testSuccess "quorum-after-remove" . withTmpDirectory $ setup 1 $ \h port -> do
                self <- getSelfPid
                node0 <- getSelfNode
                node1 <- liftIO $ newLocalNode transport remoteTables
                node2 <- liftIO $ newLocalNode transport remoteTables

                let interceptor "Increment." = send self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                liftIO $ runProcess node1 $ registerInterceptor $ interceptor
                liftIO $ runProcess node2 $ registerInterceptor $ interceptor

                forM_ [node1, node2] $ \lnid -> liftIO $ runProcess lnid $ do
                    here <- getSelfNode
                    void $ Log.addReplica h
                             (staticClosure $(mkStatic 'Policy.orpn)) here
                             leaseRenewalMargin

                Log.status h

                forM_ [node1, node2] $ \lnid -> liftIO $ runProcess lnid $ do
                    here <- getSelfNode
                    Log.reconfigure h $ staticClosure $(mkStatic 'Policy.notNode)
                        `closureApply` closure (staticDecode sdictNodeId) (encode here)

                State.update port $ incrementCP
                () <- expect
                say "Still alive replica increments."
          ]

    let pass = Prelude.read $ if null args then "FirstPass" else head args
        durability_test = testSuccess "durability" $ do
            let tmpdir = "/tmp/tmp.durability-test"
                expectedState = case pass of FirstPass -> 1; SecondPass -> 2
            when (pass == FirstPass) $
                doesDirectoryExist tmpdir >>=
                (`when` removeDirectoryRecursive tmpdir)
            createDirectoryIfMissing True tmpdir
            setCurrentDirectory tmpdir
            setup 5 $ \_ port -> do
                State.update port $ incrementCP
                assert . (== expectedState) =<< State.select sdictInt port readCP

    return $ testGroup "replicated-log" [ut, durability_test]
