--
-- Copyright (C) 2013 Seagate Technology LLC and/or its Affiliates. Apache License, Version 2.0.
--

{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

import Test.Framework (withTmpDirectory)
import Transport

import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import Control.Distributed.Process.Monitor (retryMonitoring)
import Control.Distributed.Log as Log
import Control.Distributed.Log.Snapshot
import Control.Distributed.State as State

import Control.Distributed.Process hiding (bracket, catch, die, onException, try)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Scheduler
    ( withScheduler, schedulerIsEnabled, __remoteTable )
import Control.Distributed.Static ( staticApply, staticClosure )
import Network.Transport (Transport(..))

import Control.Monad (when, forM_, replicateM, foldM_, void)
import Control.Monad.Catch
import Data.Constraint (Dict(..))
import qualified Data.Map as Map
import Data.Typeable (Typeable)
import Data.IORef
import Data.List (isPrefixOf)
import Data.Ratio ((%))
import System.Exit (die)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO
import System.Posix.Env (setEnv)
import System.Random (randomIO, mkStdGen, random, randoms)


type State = [Int]

dictState :: Dict (Typeable State)
dictState = Dict

state0 :: State
state0 = []

testLog :: State.Log State
testLog = State.log $ serializableSnapshot snapshotServerLbl state0

snapshotServerLbl :: String
snapshotServerLbl = "snapshot-server"

snapshotServer :: Process ()
snapshotServer = void $
    serializableSnapshotServer snapshotServerLbl
                               (filepath "replica-snapshots")

testLogId :: LogId
testLogId = toLogId "test-log"

testPersistDirectory :: NodeId -> FilePath
testPersistDirectory = filepath "replicas"

-- | microseconds/transition
clockSpeed :: Int
clockSpeed = 4000

retryTimeout :: Int
retryTimeout = 1500000

testConfig :: Log.Config
testConfig = Log.Config
    { logId             = testLogId
    , consensusProtocol = \dict -> BasicPaxos.protocol dict 3000000
                 (\_ -> do
                    mref <- newIORef Map.empty
                    vref <- newIORef Nothing
                    return AcceptorStore
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
    , persistDirectory  = testPersistDirectory
    , leaseTimeout      = 2 * retryTimeout
    , leaseRenewTimeout = 1000000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= 100)
    , snapshotRestoreTimeout = 1000000
    }

ssdictState :: SerializableDict State
ssdictState = SerializableDict

killOnError :: ProcessId -> Process a -> Process a
killOnError pid p = catch p $ \e -> liftIO (print e) >>
  exit pid (show (e :: SomeException)) >> liftIO (throwM e)

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

remotable [ 'dictState, 'testLog, 'ssdictState, 'testConfig, 'snapshotServer
          , 'testPersistDirectory
          ]

boolToMaybe :: Bool -> Maybe ()
boolToMaybe True  = Just ()
boolToMaybe False = Nothing

remotableDecl [ [d|

  consInt :: Int -> State -> Process State
  consInt x = return . (x:)

  readInts :: State -> Process State
  readInts = return

  testReplica :: (ProcessId,Int,RemoteHandle (Command State)) -> Process ()
  testReplica (self,x,rHandle) = killOnError self $ do
    h <- Log.clone rHandle
    port <- State.newPort h
    retryMonitoring (Log.monitorLog h) retryTimeout $
      fmap boolToMaybe $ State.update port $ $(mkClosure 'consInt) x
    newState <- retryMonitoring (Log.monitorLog h) retryTimeout $
      State.select $(mkStatic 'ssdictState) port $(mkStaticClosure 'readInts)
    usend self (x,reverse newState)

 |] ]

sdictState :: Static (Dict (Typeable State))
sdictState = $(mkStatic 'dictState)

remoteTables :: RemoteTable
remoteTables =
  Main.__remoteTable $
  Main.__remoteTableDecl $
  Control.Distributed.Process.Consensus.__remoteTable $
  Control.Distributed.Process.Scheduler.__remoteTable $
  BasicPaxos.__remoteTable $
  Log.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable


main :: IO ()
main = do
 hSetBuffering stdout LineBuffering
 hSetBuffering stderr LineBuffering
 argv <- getArgs
 let useTCP = case argv of
      ("tcp":_)   -> [mkTCPTransport]
      ("all":_)   -> [mkTCPTransport, mkInMemoryTransport]
      _           -> [mkInMemoryTransport]
 setEnv "DP_SCHEDULER_ENABLED" "1" True
 if not schedulerIsEnabled
   then die "The deterministic scheduler is not enabled."
   else do
     args <- getArgs
     s <- case args of
            "single" : _ -> randomIO
            sstr : _ -> return (read sstr)
            _ -> randomIO
     mapM_ (go args s) useTCP
  where
    go args s open =
      case args of
        _ : istr : _ ->
          bracket open (closeAbstractTransport)
            $ \(AbstractTransport transport _ _) ->
              run transport $ read istr
        _ -> bracket open (closeAbstractTransport)
             $ \(AbstractTransport transport _ _) -> do
               putStrLn $ "Running " ++ show numIterations ++ " random tests..."
               putStrLn $ "initial seed: " ++ show s
               forM_ (zip [1..] $ take numIterations $ randoms $ mkStdGen s) $
                 \(i, si) -> do
                   when (i `mod` 10 == (0 :: Int)) $
                     putStrLn $ show i ++ " iterations"
                   run transport si
               putStrLn $ "SUCCESS!"
        where
          numIterations = 50

run :: Transport -> Int -> IO ()
run transport s = withTmpDirectory $
    withScheduler (fst $ random $ mkStdGen s) clockSpeed 2
      transport remoteTables $ \others -> do
    here <- getSelfNode
    let tries = length nodes
        nodes = here : map localNodeId others
    forM_ nodes $ \n -> spawn n
                              $(mkStaticClosure 'snapshotServer)
    Log.new $(mkStatic 'State.commandEqDict)
            ($(mkStatic 'State.commandSerializableDict)
               `staticApply` sdictState)
            (staticClosure $(mkStatic 'testConfig))
            (staticClosure $(mkStatic 'testLog))
            nodes
    h <- Log.spawnReplicas testLogId
                           $(mkStaticClosure 'testPersistDirectory)
                           nodes
    rHandle <- remoteHandle h
    self <- getSelfPid
    let xs = [1..tries]
    forM_ [0..tries-1] $ \j -> do
      spawnLocal $ testReplica (self, xs !! j ,rHandle)
      -- spawn (localNodeId $ nodes !! j)
      --  $ $(mkClosure 'testReplica) (self, xs !! j ,rHandle)
    states <- replicateM tries (expect :: Process (Int,State))
    let compareStates :: [Int] -> (Int,[Int]) -> Process [Int]
        compareStates state (x,newState) = do
          -- test that updates are not missed
          when (all (x /=) newState) $ fail $ "Test failed: update missed: "
                                             ++ show x ++ " " ++ show newState
          -- test that states do not diverge
          if state `isPrefixOf` newState then
            return newState
           else if newState `isPrefixOf` state then
            return state
           else
            fail $ "Test failed: states diverged: " ++ show state ++ " "
                   ++ show newState
    foldM_ compareStates [] states
   `onException` liftIO (putStrLn $ "failure seed " ++ show s)


-- | Like 'runProcess' but forwards exceptions and returns the result of the
-- 'Process' computation.
runProcess' :: LocalNode -> Process a -> IO a
runProcess' n p = do
  r <- newIORef undefined
  runProcess n (try p >>= liftIO . writeIORef r)
    >> readIORef r
      >>= either (\e -> throwM (e :: SomeException)) return

brackets :: Int -> IO a -> (a -> IO ()) -> ([a] -> IO b) -> IO b
brackets n c r action = go id n
  where go acc i | i>0 = bracket c r $ \a -> go (acc . (a:)) (i-1)
        go acc _ = action (acc [])
