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
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import Control.Distributed.Process.Consensus.Paxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log (Config(..))
import Control.Distributed.Log.Snapshot
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import Control.Distributed.Log.Persistence as P
import Control.Distributed.Log.Persistence.LevelDB
import qualified Control.Distributed.Log.Policy as Policy

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Data.Constraint (Dict(..))
import Data.IORef
import qualified Data.Map as Map
import Data.Ratio ((%))
import Data.Typeable (Typeable)
import Data.String (fromString)
import Network.Transport ( Transport )
import Network.Transport.TCP

import System.Directory
import System.FilePath
import System.IO
import Control.Monad (replicateM_, replicateM, when, void, forM_)

import Prelude hiding (read)


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

snapshotThreashold :: Int
snapshotThreashold = 1000

testConfig :: Log.Config
testConfig = Log.Config
    { logName = "test-log"
    , consensusProtocol = \dict ->
               BasicPaxos.protocol dict 1000000
                 (\n -> do
                    mref <- newIORef Map.empty
                    let dToPair (DecreeId l dn) = (fromEnum l, dn)
                    ps <- openPersistentStore (filepath "acceptors" n)
                    pm <- P.getMap ps $ fromString "decrees"
                    pv <- P.getMap ps $ fromString "values"
                    vref <- P.lookup pv 0 >>= newIORef
                    return AcceptorStore
                      { storeInsert = \d v -> do
                          modifyIORef mref $ Map.insert d v
                          P.atomically ps [ P.Insert pm (dToPair d) v ]
                      , storeLookup = \d -> do
                          r <- readIORef mref
                          return $ maybe (Left False) Right $ Map.lookup d r
                      , storePut = \v -> do
                          writeIORef vref $ Just v
                          P.atomically ps [ P.Insert pv (0 :: Int) v ]
                      , storeGet = readIORef vref
                      , storeTrim = const $ return ()
                      , storeClose = return ()
                      }
                 )
    , persistDirectory  = filepath "replicas"
    , leaseTimeout      = 3000000
    , leaseRenewTimeout = 1000000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreashold)
    , snapshotRestoreTimeout = 1000000
    }

remotableDecl [ [d|

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
                    state0

 |] ]

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
        State.update port incrementCP >> send self ()
      replicateM_ readNo $ spawnLocal $
        State.select sdictInt port readCP >> send self ()
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
  Log.__remoteTableDecl $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable


main :: IO ()
main = do

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
             State.update port incrementCP >> send self ()
           replicateM_ readNo $ spawnLocal $
             State.select sdictInt port readCP >> send self ()
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
           mapM_ (\p -> send p rh) pds
           replicateM_ (length nodes) $ (receiveChan rp :: Process ())
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
    setup' _nd nodes = do
      forM_ nodes $ flip spawn $(mkStaticClosure 'snapshotServer)
      h <- Log.new $(mkStatic 'State.commandEqDict)
                   ($(mkStatic 'State.commandSerializableDict)
                     `staticApply` sdictState)
                   (staticClosure $(mkStatic 'testConfig))
                   (staticClosure $(mkStatic 'testLog))
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
