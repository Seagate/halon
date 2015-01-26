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
{-# LANGUAGE TypeFamilies #-}

import Criterion.Measurement (getTime, secs)
import Control.Concurrent.MVar

import Control.Distributed.Process.Consensus
    ( __remoteTable )
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log (Config(..))
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
import Data.Constraint (Dict(..))
import Data.Ratio ((%))
import Data.Typeable (Typeable)
import qualified Data.Vector.Unboxed as UV (fromList, replicate)
import Network.Transport ( Transport )
import Network.Transport.TCP

import Control.Applicative ((<$>))
import Statistics.Regression (olsRegress)
import System.Directory
import System.Environment
import System.FilePath
import System.IO
import Control.Monad (replicateM_, replicateM, when, forM_)
import Data.Acid as Acid
import Data.Acid.Memory as Acid
import Data.SafeCopy
import Control.Monad.State (get, put)
import Control.Monad.Reader (ask)

import Prelude hiding (read)
import qualified Prelude


type State = Int

dictState :: Dict (Typeable State)
dictState = Dict

dictNodeId :: SerializableDict NodeId
dictNodeId = SerializableDict

testLog :: State.Log State
testLog = State.log $ return 0

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

testConfig :: Log.Config
testConfig = Log.Config
    { consensusProtocol = \dict -> BasicPaxos.protocol dict (filepath "acceptors")
    , persistDirectory  = filepath "replicas"
    , leaseTimeout      = 3000000
    , leaseRenewTimeout = 1000000
    , driftSafetyFactor = 11 % 10
    }

checkMailbox :: Process ()
checkMailbox = do
    let receiveAll = do
          mm <- receiveTimeout 0 [ matchAny return ]
          case mm of
            Nothing -> return []
            Just m  -> (m :) <$> receiveAll
    msgs <- receiveAll
    when (length msgs > 10) $
      say $ show msgs ++ " !!!!!!!!!!!!!!!!!"
    self <- getSelfPid
    forM_ msgs $ flip forward self

remotableDecl [ [d|

  sdictInt :: Static (SerializableDict Int)
  sdictInt = $(mkStatic 'dictInt)

  dictInt :: SerializableDict Int
  dictInt = SerializableDict

  increment :: State -> Process State
  increment x = return $! x + 1

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
    self <- getSelfPid
    replicateM_ iters $ do
      replicateM_ updNo $ spawnLocal $
        State.update port incrementCP >> send self ()
      replicateM_ readNo $ spawnLocal $
        State.select sdictInt port readCP >> send self ()
      replicateM_ (updNo + readNo) (expect :: Process ())
    sendChan sp ()

remotable [ 'dictState, 'dictNodeId, 'testLog, 'testConfig, 'performBenchmark ]

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


data IState = IState Int

$(deriveSafeCopy 0 'base ''IState)

increaseInt :: Update IState ()
increaseInt = get >>= \(IState a ) -> a `seq` put $ IState (a+1)

getInt :: Query IState Int
getInt = ask >>= \(IState a) -> return a

$(makeAcidic ''IState ['increaseInt, 'getInt])


main2 = do
    acid <- openMemoryState (IState 0)
{-    let duCmd = do
           [(du, _)] <- fmap reads $ readProcess "du"
                          ["-s", "-b", "--exclude=acceptors", "acidtest"] ""
           print (du :: Int)
           -}
    -- replicateM_ 10 $ do
    forM_ [1..4000] $ \i -> do
       replicateM_ 1000 $ update acid IncreaseInt
    query acid GetInt >>= print
       -- putStrLn $ show (i :: Int)
      -- createCheckpoint acid
      -- createArchive acid
      -- removeDirectoryRecursive "acidtest/Archive"
      -- duCmd

main :: IO ()
main = do

    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    Right transport <- createTransport "127.0.0.1" "8035" defaultTCPParameters

--    runBench transport 20 3 0 30
--    runBench transport  1 3 30 0

--    runMultiBench transport 5 3 0 10
--    runMultiBench transport 1 3 10 0

--    runBench transport 10 5 0 30
--    runBench transport  1 5 2 0

--    runMultiBench transport 6 5 0 6
    args <- getArgs
    let iters = if null args then 10 else Prelude.read $ head args
    runMultiBench transport iters 5 1 0

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

      rs <- setup transport repNo $ \h nodes port -> do
         -- warmup
         State.update port incrementCP

         rh <- Log.remoteHandle h
         (sp, rp) <- newChan
         replicateM iters $ do
           pds <- mapM (\nd -> spawn nd ($(mkClosure 'performBenchmark)
                                           (1 :: Int, updNo, readNo, sp)
                                        )
                       ) nodes
           time_ $ do
             mapM_ (\p -> send p rh) pds
             replicateM_ (length nodes) $ (receiveChan rp :: Process ())
      let (xs, r) = olsRegress
                      [ UV.fromList $ map fromIntegral [1 .. length rs] ]
                      (UV.fromList rs)
      putStrLn $ "Replicas: " ++ show repNo ++ ", Clients: " ++ show repNo ++
                 ", Updates: " ++ show updNo ++ ", Selects: " ++ show readNo ++
                 ":"
      mapM_ (putStrLn . secs) rs
      print xs
      putStrLn $ "r^2: " ++ show r

setup :: Transport
      -> Int                      -- ^ Number of nodes to spawn group on.
      -> (Log.Handle (Command State) -> [NodeId] -> State.CommandPort State -> Process a)
      -> IO a
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
