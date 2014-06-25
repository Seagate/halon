-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This programs benchmarks groups of replicas.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE BangPatterns #-}

import Criterion.Measurement (getTime, secs)
import Control.Concurrent.MVar

import Control.Distributed.Process.Consensus
    ( __remoteTable )
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log
    ( sdictValue )
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import qualified Control.Distributed.Log.Policy as Policy

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.Transport ( Transport )
import Network.Transport.TCP

import System.Directory
import System.FilePath
import System.IO
import Control.Monad (replicateM_, replicateM, when)

import Prelude hiding (read)
import qualified Prelude


type State = Int

dictState :: Log.TypeableDict State
dictState = Log.TypeableDict

dictNodeId :: SerializableDict NodeId
dictNodeId = SerializableDict

testLog :: State.Log State
testLog = State.log $ return 0

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

remotableDecl [ [d|

  sdictInt :: Static (SerializableDict Int)
  sdictInt = $(mkStatic 'dictInt)

  dictInt :: SerializableDict Int
  dictInt = SerializableDict

  increment :: State -> Process State
  increment x = return $ x + 1

  read :: State -> Process Int
  read = return

 |] ]

incrementCP :: CP State State
incrementCP = staticClosure $(mkStatic 'increment)

readCP :: CP State Int
readCP = staticClosure $(mkStatic 'read)

performBenchmark :: (Int, Int, Int, SendPort ()) -> Process ()
performBenchmark (iters, updNo, readNo, sp) = do
    rh   <- expect :: Process (Log.RemoteHandle (Command State))
    h    <- Log.clone rh
    port <- State.newPort h
    replicateM_ iters $ do
      replicateM_ updNo $ State.update port incrementCP
      replicateM_ readNo $ State.select sdictInt port readCP
    sendChan sp ()

remotable [ 'dictState, 'dictNodeId, 'testLog, 'filepath, 'performBenchmark ]

sdictState :: Static (Log.TypeableDict State)
sdictState = $(mkStatic 'dictState)

sdictNodeId :: Static (SerializableDict NodeId)
sdictNodeId = $(mkStatic 'dictNodeId)


remoteTables :: RemoteTable
remoteTables =
  Main.__remoteTable  $
  Main.__remoteTableDecl $
  Control.Distributed.Process.Consensus.__remoteTable $
  BasicPaxos.__remoteTable $
  Log.__remoteTable $
  Log.__remoteTableDecl $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable


main :: IO ()
main = do

    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    Right transport <- createTransport "127.0.0.1" "8035" defaultTCPParameters

    runBench transport 20 3 0 30
    runBench transport  1 3 30 0

    runMultiBench transport 5 3 0 10
    runMultiBench transport 1 3 10 0

    runBench transport 10 5 0 30
    runBench transport  1 5 30 0

    runMultiBench transport 6 5 0 6
    runMultiBench transport 1 5 6 0

  where
    rmrf d = doesDirectoryExist d >>= flip when (removeDirectoryRecursive d)

    -- | @runBench transport iters repNo updNo readNo@ creates @repN@ replicas
    -- and sends @updNo@ updates and @readNo@ reads to one of the replicas.
    -- The above is repeated @iters@ times.
    runBench :: Transport -> Int -> Int -> Int -> Int -> IO ()
    runBench transport iters repNo updNo readNo = do
      mapM_ rmrf ["replicas", "acceptors"]

      r <- setup transport repNo $ \_ _ port -> do
         time_ $ replicateM_ iters $ do
           replicateM_ updNo $ State.update port incrementCP
           replicateM_ readNo $ State.select sdictInt port readCP
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: 1" ++
                 ", Updates: " ++ show updNo ++ ", Selects: " ++ show readNo ++
                 ": " ++ secs (r / fromIntegral iters)

    -- | @runMultiBench transport iters repNo updNo readNo@ creates @repN@
    -- replicas and sends @updNo@ updates and @readNo@ reads to each of the
    -- replicas. The above is repeated @iters@ times.
    runMultiBench :: Transport -> Int -> Int -> Int -> Int -> IO ()
    runMultiBench transport iters repNo updNo readNo = do
      mapM_ rmrf ["replicas", "acceptors"]

      r <- setup transport repNo $ \h nodes port -> do
         rh <- Log.remoteHandle h
         (sp, rp) <- newChan
         pds <- mapM (\nd -> spawn nd ($(mkClosure 'performBenchmark)
                                         (iters,updNo, readNo, sp)
                                      )
                     ) (drop 1 nodes)
         time_ $ do
           mapM_ (\p -> send p rh) pds
           replicateM_ (length nodes - 1) $ (receiveChan rp :: Process ())
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: " ++ show repNo ++
                 ", Updates: " ++ show updNo ++ ", Selects: " ++ show readNo ++
                 ": " ++ secs (r / fromIntegral iters)

setup :: Transport
      -> Int                      -- ^ Number of nodes to spawn group on.
      -> (Log.Handle (Command State) -> [NodeId] -> State.CommandPort State -> Process Double)
      -> IO Double
setup transport num action = do
    nd <- newLocalNode transport remoteTables
    box <- newEmptyMVar
    runProcess nd $ do
      node0 <- getSelfNode
      nodes <- replicateM (num - 1) $ liftIO $ newLocalNode transport remoteTables
      liftIO . putMVar box =<< setup' nd (node0 : map localNodeId nodes)
    takeMVar box
  where
    setup' nd nodes = do
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
                   1000000
                   nodes
      port <- State.newPort h
      action h nodes port

time_ :: Process () -> Process Double
time_ act = do
  start <- liftIO getTime
  act
  end <- liftIO getTime
  let !delta = end - start
  return delta
