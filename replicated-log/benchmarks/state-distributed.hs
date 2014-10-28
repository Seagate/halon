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

import Control.Distributed.Commands.DigitalOcean
    ( withDigitalOceanDo
    , NewDropletArgs(..)
    , getCredentialsFromEnv
    )
import Control.Distributed.Test (IP(..), withMachineIPs, copyFilesTo)
import Control.Distributed.Test.Process (spawnNodes, __remoteTable, spawnNode, copyLog, allMessages)
import Control.Distributed.Test.Providers.DigitalOcean (createCloudProvider)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Data.Binary (encode)
import Network.Transport ( Transport )
import Network.Transport.TCP

import System.Directory
import System.Environment (getArgs)
import System.FilePath
import System.IO
import Control.Monad (replicateM_, when, forM_, forever)


type State = Int

time_ :: Process () -> Process Double
time_ act = do
  start <- liftIO getTime
  act
  end <- liftIO getTime
  let !delta = end - start
  return delta

remotableDecl [ [d|

  testLog :: State.Log State
  testLog = State.log $ return 0

  filepath :: FilePath -> NodeId -> FilePath
  filepath prefix nid = prefix </> show (nodeAddress nid)

  dictState :: Log.TypeableDict State
  dictState = Log.TypeableDict

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
    replicateM_ iters $ do
      replicateM_ updNo $ State.update port incrementCP
      replicateM_ readNo $ State.select sdictInt port readCP
    sendChan sp ()

  incrementCP :: CP State State
  incrementCP = staticClosure $(mkStatic 'increment)

  readCP :: CP State Int
  readCP = staticClosure $(mkStatic 'read)

  cleanupFileSystem :: Process ()
  cleanupFileSystem = liftIO $ mapM_ rmrf ["replicas", "acceptors"]
    where
      rmrf :: FilePath -> IO ()
      rmrf d = doesDirectoryExist d >>= flip when (removeDirectoryRecursive d)

 |] ]

setupRemote :: [NodeId]
            -> (  Log.Handle (Command State)
               -> [NodeId]
               -> State.CommandPort State
               -> Process Double
               )
      -> Process Double
setupRemote nodes action = do
    forM_ nodes $ \n -> call sdictUnit n $(mkStaticClosure 'cleanupFileSystem)
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
      replicateM_ updNo $ State.update port incrementCP
      replicateM_ readNo $ State.select sdictInt port readCP

sdictState :: Static (Log.TypeableDict State)
sdictState = $(mkStatic 'dictState)


remotable [ 'setupRemote, 'multiBenchAction, 'benchAction ]

remoteTables :: RemoteTable
remoteTables =
  Main.__remoteTable  $
  Main.__remoteTableDecl $
  Control.Distributed.Test.Process.__remoteTable $
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
      ["--test"] -> do
         Right transport <- createTransport "127.0.0.1" "9091" defaultTCPParameters
         n <- newLocalNode transport remoteTables
         runProcess n $ do
           (nid,w) <- spawnNode (IP "localhost") "/home/dev/halon/replicated-log/dist/build/state-distributed/state-distributed --slave `hostname -I` 2>&1"
           liftIO $ print nid
           nsendRemote nid "finalizer" ()
           liftIO $ putStrLn "waiting finalizer"
           liftIO w
           
      ["--slave", ip_addr] -> do
         Right transport <- createTransport ip_addr "9090" defaultTCPParameters
         n <- newLocalNode transport remoteTables
         print $ encode $ localNodeId n
         putStrLn ""
         hFlush stdout
         runProcess n $ do
           getSelfPid >>= register "finalizer"
           expect :: Process () -- wait for death
         putStrLn "done!"
      _ -> withDigitalOceanDo $ do

        Just credentials <- getCredentialsFromEnv
        cp <- createCloudProvider credentials $ return NewDropletArgs
            { name        = "test-droplet"
            , size_slug   = "512mb"
            , image_id    = "7055005"
            , region_slug = "ams2"
            , ssh_key_ids = ""
            }
        Right transport <- createTransport "127.0.0.1" "8035" defaultTCPParameters
        withMachineIPs cp 5 $ \ms5 -> do
          let ms3 = take 3 ms5

          copyFilesTo (IP "localhost")
                      ms5
                      [("dist/build/state-distributed/state-distributed","state-distributed")]

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
    runBench :: Transport -> [IP] -> Int -> Int -> Int -> IO ()
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
    runMultiBench :: Transport -> [IP] -> Int -> Int -> Int -> IO ()
    runMultiBench transport ms iters updNo readNo = do

      let repNo = length ms
      r <- setup transport
                 ms
                 ($(mkClosure 'multiBenchAction) (repNo, updNo, readNo))
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: " ++ show repNo ++
                 ", Updates: " ++ show updNo ++ ", Selects: " ++ show readNo ++
                 ": " ++ secs (r / fromIntegral iters)

setup :: Transport
      -> [IP]
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
      nidWaits <- spawnNodes ms "./state-distributed --slave `hostname -I` 2>&1"
      let (nids, waitTerminations) = unzip nidWaits
      _ <- spawnLocal $ do mapM_ (flip copyLog allMessages) nids
                           forever $ do
                             (pid, msg) <- expect :: Process (ProcessId, String)
                             liftIO $ putStrLn $ show pid ++ " " ++ msg
      liftIO $ putStrLn "call setupRemote"
      liftIO . putMVar box =<<
        call $(mkStatic 'dictDouble)
             (head nids)
             ($(mkClosure 'setupRemote) nids `closureApply` action)
      liftIO $ putStrLn "waiting for termination"
      forM_ nidWaits $ \(n, waitForTermination) ->
        nsendRemote n "finalizer" () >> liftIO waitForTermination
    takeMVar box
