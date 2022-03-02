--
-- Copyright (C) 2013 Seagate Technology LLC and/or its Affiliates. Apache License, Version 2.0.
--

{-# LANGUAGE TemplateHaskell #-}

import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos

import Control.Distributed.Process hiding (bracket, catch, die, onException)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Scheduler
    (schedulerIsEnabled, withScheduler, __remoteTable)
import Network.Transport (Transport(..))
import qualified Network.Transport.InMemory as InMemory

import Control.Monad (when, forM, forM_, replicateM_)
import Control.Monad.Catch
import Data.IORef
import qualified Data.Map as Map
import System.Exit (die)
import System.Environment (getArgs)
import System.IO
import System.Posix.Env (setEnv)
import System.Random (randomIO, split, mkStdGen, random, randoms, randomRs)

remoteTables :: RemoteTable
remoteTables =
  Control.Distributed.Process.Consensus.__remoteTable $
  Control.Distributed.Process.Scheduler.__remoteTable $
  BasicPaxos.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

main :: IO ()
main = do
 setEnv "DP_SCHEDULER_ENABLED" "1" True
 hSetBuffering stdout LineBuffering
 hSetBuffering stderr LineBuffering
 if not schedulerIsEnabled
   then die "The deterministic scheduler is not enabled."
   else do
     args <- getArgs
     s <- case args of
            "single" : _ -> randomIO
            sstr : _ -> return (read sstr)
            _ -> randomIO
     let numIterations = 50
     case args of
       _ : istr : _ -> run $ read istr
       _ -> do
         liftIO $ do putStrLn $ "Running " ++ show numIterations
                                ++ " random tests..."
                     putStrLn $ "initial seed: " ++ show s
         forM_ (zip [1..] $ take numIterations $ randoms $ mkStdGen s) $
           \(i, si) -> do
             when (i `mod` 10 == (0 :: Int)) $
               liftIO $ putStrLn $ show i ++ " iterations"
             run si
     putStrLn "SUCCESS!"

-- | microseconds/transition
clockSpeed :: Int
clockSpeed = 10000

run :: Int -> IO ()
run s = bracket InMemory.createTransport closeTransport $ \transport ->
    let (s0,s1) = split $ mkStdGen s
     in withScheduler (fst $ random s0) clockSpeed 1 transport remoteTables
              $ \_ -> do
  let procs = 5
  αs <- forM [1..procs] $ \n -> do
          mref <- liftIO $ newIORef Map.empty
          vref <- liftIO $ newIORef Nothing
          spawnLocal $
            acceptor (error "undefined Test.acceptor.send")
                 (undefined :: Int)
                 initialDecreeId
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
                 n
  pmapR <- liftIO $ newIORef Map.empty
  self <- getSelfPid
  let rs = randomRs (1,procs) s1
      ds = take procs rs
      xs = drop procs rs
  forM_ [0..procs-1] $ \j -> spawnLocal $ killOnError self $ do
    let d = ds !! j
        x = xs !! j
    x' <- runPropose (propose 1000000 usend αs (DecreeId 0 d) x)
    ok <- liftIO $ atomicModifyIORef pmapR $ \pmap ->
      case Map.lookup d pmap of
        Nothing  -> (Map.insert d x' pmap, True)
        Just x'' -> (pmap, x'' == x')
    when (not ok) $ fail "Test failed"
    usend self ()
  replicateM_ procs (expect :: Process ())
 `onException` liftIO (putStrLn $ "failure seed " ++ show s)

killOnError :: ProcessId -> Process a -> Process a
killOnError pid p = catch p $ \e -> liftIO (print e) >>
  exit pid (show (e :: SomeException)) >> liftIO (throwM e)
