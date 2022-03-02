-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This program benchmarks groups of replicas on various hosts.
--
-- The program creates 50 satellites and 5 tracking station nodes.
-- The satellites are then used to deliver some 1200 requests to the tracking
-- station.
--

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

import Control.Concurrent.MVar

import Control.Distributed.Process.Consensus
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log (Config(..))
import Control.Distributed.Log.Snapshot
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import Control.Distributed.Log.Persistence.LevelDB
import Control.Distributed.Log.Persistence.Paxos (acceptorStore)
import qualified Control.Distributed.Log.Policy as Policy
import Test.Framework (withTmpDirectory)

import Control.Distributed.Commands (waitForCommand_)
import Control.Distributed.Commands.Management
    ( HostName
    , withHostNames
    , copyFiles
    )
import Control.Distributed.Commands.Process
    ( spawnNode
    , __remoteTable
    , sendSelfNode
    , NodeHandle(..)
    )
import Control.Distributed.Commands.Providers
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Monitor
import Control.Distributed.Static
import Network.Transport ( Transport )
import Network.Transport.TCP

import Control.Concurrent (threadDelay, readChan, writeChan)
import qualified Control.Concurrent as C
import Data.Constraint (Dict(..))
import Data.IORef
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Ratio ((%))
import Data.Typeable (Typeable, Proxy(..))
import System.Clock
import System.Environment
import System.FilePath
import System.IO
import System.IO.Unsafe
import Control.Monad
import Text.Printf


retryLog :: Log.Handle a -> Process (Maybe b) -> Process b
retryLog h = retryMonitoring (Log.monitorLog h) 2000000

type State = Int

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

state0 :: State
state0 = 0

snapshotServerLbl :: String
snapshotServerLbl = "snapshot-server"

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

snapshotThreshold :: Int
snapshotThreshold = 10000

testLogId :: Log.LogId
testLogId = Log.toLogId "test-log"

bToM :: Bool -> Maybe ()
bToM True  = Just ()
bToM False = Nothing

{-# NOINLINE globalCount #-}
globalCount :: IORef Int
globalCount = unsafePerformIO $ newIORef 1

remotableDecl [ [d|

  testLog :: State.Log State
  testLog = State.log $ serializableSnapshot snapshotServerLbl state0

  dictState :: Dict (Typeable State)
  dictState = Dict

  testPersistDirectory :: NodeId -> FilePath
  testPersistDirectory = filepath "replicas"

  testConfig :: Log.Config
  testConfig = Log.Config
    { logId = testLogId
    , consensusProtocol = \dict ->
               BasicPaxos.protocol dict 3000000
                 (\n -> openPersistentStore (filepath "acceptors" n) >>=
                          acceptorStore
                 )
    , persistDirectory  = testPersistDirectory
    , leaseTimeout      = 4000000
    , leaseRenewTimeout = 2000000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreshold)
    , snapshotRestoreTimeout = 1000000
    }

  dictInt :: SerializableDict Int
  dictInt = SerializableDict

  sdictInt :: Static (SerializableDict Int)
  sdictInt = $(mkStatic 'dictInt)

  increment :: State -> Process State
  increment x = return $ x + 1

  read :: State -> Process Int
  read = return

  performBenchmark :: (Int, Int, Int, SendPort ()) -> Process ()
  performBenchmark (iters, updNo, readNo, sp) = do
    rh   <- expect :: Process (Log.RemoteHandle (Command State))
    h    <- Log.clone rh
    port <- State.newPort h
    self <- getSelfPid
    replicateM_ iters $ do
      replicateM_ updNo $ spawnLocal $ do
        retryLog h $ bToM <$>
          State.update port incrementCP
        i <- liftIO $ atomicModifyIORef' globalCount $ \i -> (i + 1, i)
        when (i `mod` 10 == 0) $
          liftIO $ hPutStrLn stderr $ "Count: " ++ show i
        usend self ()
      replicateM_ readNo $ spawnLocal $ do
        _ <- retryLog h $
          State.select sdictInt port readCP
        usend self ()
      replicateM_ (updNo + readNo) (expect :: Process ())
    sendChan sp ()

  incrementCP :: CP State State
  incrementCP = staticClosure $(mkStatic 'increment)

  readCP :: CP State Int
  readCP = staticClosure $(mkStatic 'read)

  snapshotServer :: Process ()
  snapshotServer = void $ serializableSnapshotServer
                    snapshotServerLbl
                    (filepath "replica-snapshots")

 |] ]

setupRemote :: (ProcessId, [NodeId], [NodeId])
            -> (  Log.Handle (Command State)
               -> [NodeId]
               -> State.CommandPort State
               -> Process Double
               )
      -> Process ()
setupRemote (caller, tsNodes, clientNodes) action =
    bracket (forM tsNodes $ flip
                 spawn $(mkStaticClosure 'snapshotServer)
              )
              (mapM_ $ \pid -> exit pid "setup" >> waitFor pid) $
              const $
    bracket (do
                forM_ tsNodes $ flip spawn $(mkStaticClosure 'snapshotServer)
                Log.new
                  $(mkStatic 'State.commandEqDict)
                  ($(mkStatic 'State.commandSerializableDict)
                    `staticApply` sdictState)
                  (staticClosure $(mkStatic 'testConfig))
                  (staticClosure $(mkStatic 'testLog))
                  tsNodes
                Log.spawnReplicas
                  testLogId
                  $(mkStaticClosure 'testPersistDirectory)
                  tsNodes
            )
            (\h -> forM_ tsNodes (\n -> Log.killReplica h n))
            $ \h -> do
      port <- State.newPort h
      action h clientNodes port >>= usend caller
  where
    waitFor pid = monitor pid >> receiveWait
                    [ matchIf (\(ProcessMonitorNotification _ pid' _) ->
                                   pid == pid'
                              )
                              $ const $ return ()
                    ]

multiBenchAction :: (Int, Int, Int)
                 -> Log.Handle (Command State)
                 -> [NodeId]
                 -> State.CommandPort State
                 -> Process Double
multiBenchAction (iters, updNo, readNo) = \h nodes _port -> do
    rh <- Log.remoteHandle h
    (sp, rp) <- newChan
    pds <- mapM (\nd -> spawn nd ($(mkClosure 'performBenchmark)
                                    (iters,updNo, readNo, sp)
                                 )
                ) nodes
    -- Make an update to ensure the replicas are ready before starting.
    port <- State.newPort h
    State.update port incrementCP
    time_ $ do
      mapM_ (\p -> usend p rh) pds
      replicateM_ (length nodes) $ (receiveChan rp :: Process ())

benchAction :: (Int, Int, Int)
            -> Log.Handle (Command State)
            -> [NodeId]
            -> State.CommandPort State
            -> Process Double
benchAction (iters, updNo, readNo) = \h _ port -> do
    time_ $ replicateM_ iters $ do
      self <- getSelfPid
      replicateM_ iters $ do
        replicateM_ updNo $ spawnLocal $ do
          retryLog h $ bToM <$>
            State.update port incrementCP
          usend self ()
        replicateM_ readNo $ spawnLocal $ do
          _ <- retryLog h $
            State.select sdictInt port readCP
          usend self ()
        replicateM_ (updNo + readNo) (expect :: Process ())

sdictState :: Static (Dict (Typeable State))
sdictState = $(mkStatic 'dictState)


remotable [ 'setupRemote, 'multiBenchAction, 'benchAction ]

remoteTables :: RemoteTable
remoteTables =
  Main.__remoteTable  $
  Main.__remoteTableDecl $
  Control.Distributed.Commands.Process.__remoteTable $
  Control.Distributed.Process.Consensus.__remoteTable $
  BasicPaxos.__remoteTable $
  Log.__remoteTable $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable


main :: IO ()
main =
    hSetBuffering stdout LineBuffering >>
    hSetBuffering stderr LineBuffering >>
    -- setEnv "HALON_TRACING" "replicated-log consensus-paxos" >>
    getArgs >>= \args ->
    case args of
      ["--slave", ip_addr] -> withTmpDirectory $ do
         Right transport <- createTransport ip_addr "9090" defaultTCPParameters
         n <- newLocalNode transport remoteTables
         runProcess n $ do
           sendSelfNode
           getSelfPid >>= register "finalizer"
           expect :: Process () -- wait for death
      _ -> do

        cp <- getProvider
        ip <- getHostAddress
        Right transport <- createTransport ip "8035" defaultTCPParameters
        let numNodes = 50 + 5
        withHostNames cp numNodes $ \msAll -> do
          let -- ms3 = take 3 msAll
              ms5 = take 5 msAll
              ms = drop 5 msAll

          exePath <- getExecutablePath
          copyFiles "localhost"
                    msAll
                    [ ( exePath
                      , "/tmp/state-distributed"
                      )
                    ]

          -- runBench transport ms3 1   0 600
          -- runBench transport ms3 1 600   0

          -- runMultiBench transport ms3 1   0 200
          -- runMultiBench transport ms3 1 200   0

          -- runBench transport ms5 1   0 600
          -- runBench transport ms5 1 600   0

          -- runMultiBench transport ms5 1   0 120
          -- runMultiBench transport ms5 1 120   0

          forM_ [10,20..(numNodes - 5)] $ \i -> do
            let nRqs = 1200 `div` i
            runMultiBench' transport ms5 (take i ms) nRqs    0

  where
    -- | @runBench transport ms iters updNo readNo@ creates replicas on
    -- machines @ms@ and sends @updNo@ updates and @readNo@ reads to one
    -- of the replicas. The above is repeated @iters@ times.
    runBench :: Transport -> [HostName] -> Int -> Int -> Int -> IO ()
    runBench transport ms iters updNo readNo = do

      let repNo = length ms
      r <- setup transport
                 ms ms
                 ($(mkClosure 'benchAction) (iters, updNo, readNo))
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: 1" ++
                 ", Updates: " ++ show updNo ++ ", Selects: " ++ show readNo ++
                 ": " ++ secs (r / fromIntegral iters)

    -- | @runMultiBench transport ms iters updNo readNo@ creates replicas on
    -- machines @ms@ and sends @updNo@ updates and @readNo@ reads to each
    -- of the replicas. The above is repeated @iters@ times.
    runMultiBench :: Transport -> [HostName] -> Int -> Int -> Int -> IO ()
    runMultiBench transport ms iters updNo readNo = do

      let repNo = length ms
      r <- setup transport
                 ms ms
                 ($(mkClosure 'multiBenchAction) (iters, updNo, readNo))
      putStrLn $ "Replicas: " ++ show repNo ++
                 ", Clients: " ++ show repNo ++
                 ", Updates: " ++ show (updNo * repNo) ++
                 ", Selects: " ++ show (readNo * repNo) ++
                 ": " ++ secs (r / fromIntegral iters)

    runMultiBench' :: Transport -> [HostName] -> [HostName] -> Int -> Int -> IO ()
    runMultiBench' transport tsNodes clientNodes updNo readNo = do

      let cliNo = length clientNodes
      r <- setup transport
                 tsNodes
                 clientNodes
                 ($(mkClosure 'multiBenchAction) (1 :: Int, updNo, readNo))
      putStrLn $ "Replicas: " ++ show (length tsNodes) ++
                 ", Clients: " ++ show cliNo ++
                 ", Updates: " ++ show (updNo * cliNo) ++
                 ", Selects: " ++ show (readNo * cliNo) ++
                 ": " ++ secs r

setup :: Transport
      -> [HostName]
      -> [HostName]
      -> Closure (  Log.Handle (Command State)
                 -> [NodeId]
                 -> State.CommandPort State
                 -> Process Double
                 )
      -> IO Double
setup transport tsNodes clientNodes action = do
    nd <- newLocalNode transport remoteTables
    box <- newEmptyMVar
    runProcess nd $ do
      chan <- liftIO C.newChan
      forM_ (nub $ tsNodes ++ clientNodes) $ \m ->
        spawnLocal $ do
          nh <- spawnNode m $ "/tmp/state-distributed --slave " ++ m ++ " 2>&1"
          liftIO $ writeChan chan (m, nh)
      nidPairs <- forM (nub $ tsNodes ++ clientNodes) $ const $
                    liftIO $ readChan chan
      let tsNhs = catMaybes $ map (`Prelude.lookup` nidPairs) tsNodes
          clientNhs = catMaybes $ map (`Prelude.lookup` nidPairs) clientNodes
          nids = map (handleGetNodeId . snd) nidPairs
      self <- getSelfPid
      liftIO . putMVar box =<< do
        _ <- spawn (head nids)
              ($(mkClosure 'setupRemote)
                (self, map handleGetNodeId tsNhs, map handleGetNodeId clientNhs)
               `closureApply` action)
        expect :: Process Double
      mapM_ monitorNode nids
      forM_ nids $ \n -> nsendRemote n "finalizer" ()
      liftIO $ forM_ nidPairs $ \(_, nh) -> waitForCommand_ (handleGetInput nh)
    takeMVar box
