-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This programs benchmarks groups of replicas.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE BangPatterns #-}

import Control.Concurrent.MVar

import Control.Distributed.Process.Consensus
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log (Config(..))
import Control.Distributed.Log.Persistence.Paxos (acceptorStore)
import Control.Distributed.Log.Snapshot
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import Control.Distributed.Log.Persistence.LevelDB
import qualified Control.Distributed.Log.Policy as Policy
import Test.Framework (withTmpDirectory)

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Data.Constraint (Dict(..))
import Data.Ratio ((%))
import Data.Typeable (Typeable, Proxy(..))
import Network.Transport ( Transport )
import Network.Transport.TCP

import System.Clock
import System.Directory
import System.FilePath
import System.IO
import Control.Monad

import Prelude hiding (read)
import Text.Printf


type State = Int

dictState :: Dict (Typeable State)
dictState = Dict

state0 :: State
state0 = 0

snapshotServerLbl :: String
snapshotServerLbl = "snapshot-server"

testLog :: State.Log State
testLog = State.log $ serializableSnapshot snapshotServerLbl state0

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

snapshotThreshold :: Int
snapshotThreshold = 1000

testLogId :: Log.LogId
testLogId = Log.toLogId "test-log"

remotableDecl [ [d|

  testPersistDirectory :: NodeId -> FilePath
  testPersistDirectory = filepath "replicas"

  dictInt :: SerializableDict Int
  dictInt = SerializableDict

  increment :: State -> Process State
  increment x = return $ x + 1

  read :: State -> Process Int
  read = return

  snapshotServer :: Process ()
  snapshotServer = void $ serializableSnapshotServer
                    snapshotServerLbl
                    (filepath "replica-snapshots")
 |] ]

testConfig :: Log.Config
testConfig = Log.Config
    { logId = testLogId
    , consensusProtocol = \dict ->
               BasicPaxos.protocol dict 1000000
                 (\n -> openPersistentStore (filepath "acceptors" n) >>=
                          acceptorStore
                 )
    , persistDirectory  = testPersistDirectory
    , leaseTimeout      = 2000000
    , leaseRenewTimeout = 300000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreshold)
    , snapshotRestoreTimeout = 1000000
    }

sdictInt :: Static (SerializableDict Int)
sdictInt = $(mkStatic 'dictInt)

incrementCP :: CP State State
incrementCP = staticClosure $(mkStatic 'increment)

readCP :: CP State Int
readCP = staticClosure $(mkStatic 'read)

performBenchmark :: (Int, Int, Int, SendPort ()) -> Process ()
performBenchmark (iters, updNo, readNo, sp) = do
    rh   <- expect :: Process (Log.RemoteHandle (Command State))
    h    <- Log.clone rh
    port <- State.newPort h
    self <- getSelfPid
    replicateM_ iters $ do
      replicateM_ updNo $ spawnLocal $
        State.update port incrementCP >> usend self ()
      replicateM_ readNo $ spawnLocal $
        State.select sdictInt port readCP >> usend self ()
      replicateM_ (updNo + readNo) (expect :: Process ())
    sendChan sp ()

remotable [ 'dictState, 'testLog, 'testConfig, 'performBenchmark ]

sdictState :: Static (Dict (Typeable State))
sdictState = $(mkStatic 'dictState)


remoteTables :: RemoteTable
remoteTables =
  Main.__remoteTable  $
  Main.__remoteTableDecl $
  Control.Distributed.Process.Consensus.__remoteTable $
  BasicPaxos.__remoteTable $
  Log.__remoteTable $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable


main :: IO ()
main = withTmpDirectory $ do

    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    Right transport <- createTransport "127.0.0.1" "8035" defaultTCPParameters

    runBench transport  1 3   0 600
    runBench transport  1 3 600   0

    runMultiBench transport 1 3   0 200
    runMultiBench transport 1 3 200   0

    runBench transport  1 5   0 600
    runBench transport  1 5 600   0

    runMultiBench transport 1 5   0 120
    runMultiBench transport 1 5 120   0

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
           self <- getSelfPid
           replicateM_ updNo $ spawnLocal $
             State.update port incrementCP >> usend self ()
           replicateM_ readNo $ spawnLocal $
             State.select sdictInt port readCP >> usend self ()
           replicateM_ (updNo + readNo) (expect :: Process ())
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: 1" ++
                 ", Updates: " ++ show updNo ++ ", Selects: " ++ show readNo ++
                 ": " ++ secs (r / fromIntegral iters)

    -- | @runMultiBench transport iters repNo updNo readNo@ creates @repN@
    -- replicas and sends @updNo@ updates and @readNo@ reads to each of the
    -- replicas. The above is repeated @iters@ times.
    runMultiBench :: Transport -> Int -> Int -> Int -> Int -> IO ()
    runMultiBench transport iters repNo updNo readNo = do
      mapM_ rmrf ["replicas", "acceptors"]

      r <- setup transport repNo $ \h nodes _port -> do
         rh <- Log.remoteHandle h
         (sp, rp) <- newChan
         pds <- mapM (\nd -> spawn nd ($(mkClosure 'performBenchmark)
                                         (iters,updNo, readNo, sp)
                                      )
                     ) nodes
         time_ $ do
           mapM_ (\p -> usend p rh) pds
           replicateM_ (length nodes) $ (receiveChan rp :: Process ())
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: " ++ show repNo ++
                 ", Updates: " ++ show (updNo * repNo) ++
                 ", Selects: " ++ show (readNo * repNo) ++
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
    setup' _nd nodes =
      bracket (forM nodes $ flip
                 spawn $(mkStaticClosure 'snapshotServer)
              )
              (mapM_ $ \pid -> exit pid "setup" >> waitFor pid) $
              const $
      bracket (do
                  forM_ nodes $ flip spawn $(mkStaticClosure 'snapshotServer)
                  Log.new
                    $(mkStatic 'State.commandEqDict)
                    ($(mkStatic 'State.commandSerializableDict)
                      `staticApply` sdictState)
                    (staticClosure $(mkStatic 'testConfig))
                    (staticClosure $(mkStatic 'testLog))
                    nodes
                  Log.spawnReplicas
                    testLogId
                    $(mkStaticClosure 'testPersistDirectory)
                    nodes
              )
              (\h -> forM_ nodes (\n -> Log.killReplica h n))
              $ \h -> do
        port <- State.newPort h
        action h nodes port

    waitFor pid = monitor pid >> receiveWait
                    [ matchIf (\(ProcessMonitorNotification _ pid' _) ->
                                   pid == pid'
                              )
                              $ const $ return ()
                    ]

time_ :: Process () -> Process Double
time_ act = do
  start <- liftIO $ getTime Monotonic
  act
  end <- liftIO $ getTime Monotonic
  let !delta = diffTimeSpec end start
  return $ fromIntegral $ toNanoSecs delta `div` 10^(9::Int)

-- | Convert a number of seconds to a string.  The string will consist
-- of four decimal places, followed by a short description of the time
-- units.
--
-- Taken from the criterion package from the module Criterion.Measurements
secs :: Double -> String
secs k
    | k < 0      = '-' : secs (-k)
    | k >= 1     = k        `with` "s"
    | k >= 1e-3  = (k*1e3)  `with` "ms"
    | k >= 1e-6  = (k*1e6)  `with` "μs"
    | k >= 1e-9  = (k*1e9)  `with` "ns"
    | k >= 1e-12 = (k*1e12) `with` "ps"
    | k >= 1e-15 = (k*1e15) `with` "fs"
    | k >= 1e-18 = (k*1e18) `with` "as"
    | otherwise  = printf "%g s" k
     where with t u
               | t >= 1e9  = printf "%.4g %s" t u
               | t >= 1e3  = printf "%.0f %s" t u
               | t >= 1e2  = printf "%.1f %s" t u
               | t >= 1e1  = printf "%.2f %s" t u
               | otherwise = printf "%.3f %s" t u
