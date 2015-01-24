-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program benchmarks groups of replicas on various hosts.
--
-- The program starts by creating 5 droplets in Digital Ocean. Then it copies
-- itself to these droplets, then it runs a series of benchmarks, and then it
-- destroys the droplets.
--
-- Executing the benchmark requires defining in the environment variables
-- DO_CLIENT_ID and DO_API_KEY with your Digital Ocean credentials. Because
-- the program copies itself, the host where the program is first run has
-- to be the same platform as the one used on the droplets.
--
-- For the time being, the program uses a hardcoded image to create the
-- droplets. The image is provisioned with halon from an ubuntu system. It
-- has a user dev with halon built in its home folder. The image also has
-- /etc/ssh/ssh_config tweaked so copying files from remote to remote machine
-- does not store hosts in known_hosts.
--
-- Each benchmark has a setup phase in which Cloud Haskell nodes are started
-- on the droplets by calling this program passing the --slave command line
-- argument. Then files that could have been left by a previous benchmark are
-- deleted. After the benchmark, the processes are killed and when they die
-- the program proceeds.
--
-- The benchmarks are as follows:
--
-- * Run a group of three replicas and measure how long it takes to serve 30
-- read requests from a single client.
--
-- * Run a group of three replicas and measure how long it takes to serve 30
-- update requests from a single client.
--
-- * Run a group of three replicas and measure how long it takes to serve 10
-- read requests sent from each of three clients.
--
-- * Run a group of three replicas and measure how long it takes to serve 10
-- update requests sent from each of three clients.
--
-- The benchmarks are then repeated with 5 replicas while maintaining the total
-- amount of requests at 30 per benchmark.
--
-- In all cases the clients are colocated with the replicas.
--

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
import Control.Distributed.Log (Config(..))
import Control.Distributed.Log.Snapshot
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import qualified Control.Distributed.Log.Policy as Policy

import Control.Distributed.Commands.Management
    ( HostName
    , withHostNames
    , copyFiles
    )
import Control.Distributed.Commands.Process
    ( spawnNode
    , __remoteTable
    , redirectLogsHere
    , printNodeId
    )
import Control.Distributed.Commands.Providers
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.Transport ( Transport )
import Network.Transport.TCP
import Test.Framework (withTmpDirectory)

import Data.Constraint (Dict(..))
import Data.Ratio ((%))
import Data.Typeable (Typeable)
import System.Environment (getArgs)
import System.FilePath
import System.IO
import Control.Monad (replicateM_, forM_, forM, void)


type State = Int

time_ :: Process () -> Process Double
time_ act = do
  start <- liftIO getTime
  act
  end <- liftIO getTime
  let !delta = end - start
  return delta

state0 :: State
state0 = 0

snapshotServerLbl :: String
snapshotServerLbl = "snapshot-server"

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

snapshotThreashold :: Int
snapshotThreashold = 5

remotableDecl [ [d|

  testLog :: State.Log State
  testLog = State.log $ serializableSnapshot snapshotServerLbl state0

  dictState :: Dict (Typeable State)
  dictState = Dict

  testConfig :: Log.Config
  testConfig = Log.Config
      { consensusProtocol = \dict ->
          BasicPaxos.protocol dict (filepath "acceptors")
      , persistDirectory  = filepath "replicas"
      , leaseTimeout      = 3000000
      , leaseRenewTimeout = 1000000
      , driftSafetyFactor = 11 % 10
      , snapshotPolicy    = return . (>= snapshotThreashold)
      }

  sdictInt :: Static (SerializableDict Int)
  sdictInt = $(mkStatic 'dictInt)

  dictInt :: SerializableDict Int
  dictInt = SerializableDict

  dictDouble :: SerializableDict Double
  dictDouble = SerializableDict

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
      replicateM_ updNo $ spawnLocal $
        State.update port incrementCP >> send self ()
      replicateM_ readNo $ spawnLocal $
        State.select sdictInt port readCP >> send self ()
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
                    state0

 |] ]

setupRemote :: [NodeId]
            -> (  Log.Handle (Command State)
               -> [NodeId]
               -> State.CommandPort State
               -> Process Double
               )
      -> Process Double
setupRemote nodes action = do
    forM_ nodes $ flip spawn $(mkStaticClosure 'snapshotServer)
    h <- Log.new $(mkStatic 'State.commandEqDict)
                 ($(mkStatic 'State.commandSerializableDict)
                   `staticApply` sdictState)
                 (staticClosure $(mkStatic 'testConfig))
                 (staticClosure $(mkStatic 'testLog))
                 nodes
    port <- State.newPort h
    action h nodes port

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
                ) (drop 1 nodes)
    time_ $ do
      mapM_ (\p -> send p rh) pds
      replicateM_ (length nodes - 1) $ (receiveChan rp :: Process ())

benchAction :: (Int, Int, Int)
            -> Log.Handle (Command State)
            -> [NodeId]
            -> State.CommandPort State
            -> Process Double
benchAction (iters, updNo, readNo) = \_ _ port -> do
    time_ $ replicateM_ iters $ do
      self <- getSelfPid
      replicateM_ iters $ do
        replicateM_ updNo $ spawnLocal $
          State.update port incrementCP >> send self ()
        replicateM_ readNo $ spawnLocal $
          State.select sdictInt port readCP >> send self ()
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
  Log.__remoteTableDecl $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable


main :: IO ()
main =
    hSetBuffering stdout LineBuffering >>
    hSetBuffering stderr LineBuffering >>
    getArgs >>= \args ->
    case args of
      ["--slave", ip_addr] -> withTmpDirectory $ do
         Right transport <- createTransport ip_addr "9090" defaultTCPParameters
         n <- newLocalNode transport remoteTables
         printNodeId $ localNodeId n
         runProcess n $ do
           getSelfPid >>= register "finalizer"
           expect :: Process () -- wait for death
      _ -> do

        cp <- getProvider
        ip <- getHostAddress
        Right transport <- createTransport ip "8035" defaultTCPParameters
        withHostNames cp 5 $ \ms5 -> do
          let ms3 = take 3 ms5

          copyFiles "localhost"
                    ms5
                    [ ( "dist/build/state-distributed/state-distributed"
                      , "/tmp/state-distributed"
                      )
                    ]

          runBench transport ms3 20 0 30
          runBench transport ms3 1 30 0

          runMultiBench transport ms3 5 0 10
          runMultiBench transport ms3 1 10 0

          runBench transport ms5 10 0 30
          runBench transport ms5 1 30 0

          runMultiBench transport ms5 6 0 6
          runMultiBench transport ms5 1 6 0

  where
    -- | @runBench transport ms iters updNo readNo@ creates replicas on
    -- machines @ms@ and sends @updNo@ updates and @readNo@ reads to one
    -- of the replicas. The above is repeated @iters@ times.
    runBench :: Transport -> [HostName] -> Int -> Int -> Int -> IO ()
    runBench transport ms iters updNo readNo = do

      let repNo = length ms
      r <- setup transport
                 ms
                 ($(mkClosure 'benchAction) (repNo, updNo, readNo))
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
                 ms
                 ($(mkClosure 'multiBenchAction) (repNo, updNo, readNo))
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: " ++ show repNo ++
                 ", Updates: " ++ show updNo ++ ", Selects: " ++ show readNo ++
                 ": " ++ secs (r / fromIntegral iters)

setup :: Transport
      -> [HostName]
      -> Closure (  Log.Handle (Command State)
                 -> [NodeId]
                 -> State.CommandPort State
                 -> Process Double
                 )
      -> IO Double
setup transport ms action = do
    nd <- newLocalNode transport remoteTables
    box <- newEmptyMVar
    runProcess nd $ do
      nids <- forM ms $ \m ->
                spawnNode m $ "/tmp/state-distributed --slave " ++ m ++ " 2>&1"
      mapM_ redirectLogsHere nids
      liftIO . putMVar box =<<
        call $(mkStatic 'dictDouble)
             (head nids)
             ($(mkClosure 'setupRemote) nids `closureApply` action)
      mapM_ monitorNode nids
      forM_ nids $ \n -> nsendRemote n "finalizer" ()
      replicateM_ (length nids) (expect :: Process NodeMonitorNotification)
    takeMVar box
