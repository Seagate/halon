--
-- Copyright (C) 2013 Xyratex Technology Limited. All rights reserved.
--

{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

import Test.Framework (withTmpDirectory)
import Transport

import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import Control.Distributed.Log as Log
import Control.Distributed.Log.Snapshot
import Control.Distributed.State as State

import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Scheduler
    ( withScheduler, schedulerIsEnabled, __remoteTable )
import Control.Distributed.Static ( staticApply, staticClosure )
import Network.Transport (Transport(..))

import Control.Exception ( bracket, throwIO, SomeException )
import Control.Monad ( when, forM_, replicateM, foldM_, void )
import Data.Constraint (Dict(..))
import qualified Data.Map as Map
import Data.Typeable (Typeable, Proxy(..))
import Data.IORef
import Data.List ( isPrefixOf )
import Data.Ratio ((%))
import System.Exit ( exitFailure )
import System.Environment ( getArgs )
import System.FilePath ((</>))
import System.Posix.Env (setEnv)
import System.Random ( randomIO, mkStdGen, random, randoms )


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
                               (Proxy :: Proxy State)

testLogId :: LogId
testLogId = toLogId "test-log"

testPersistDirectory :: NodeId -> FilePath
testPersistDirectory = filepath "replicas"

testConfig :: Log.Config
testConfig = Log.Config
    { logId             = testLogId
    , consensusProtocol = \dict -> BasicPaxos.protocol dict 3000000
                 (\_ -> do
                    mref <- newIORef Map.empty
                    vref <- newIORef Nothing
                    return AcceptorStore
                      { storeInsert = \d v -> do
                          modifyIORef mref $ Map.insert d v
                      , storeLookup = \d -> do
                          r <- readIORef mref
                          return $ maybe (Left False) Right $ Map.lookup d r
                      , storePut = writeIORef vref . Just
                      , storeGet = readIORef vref
                      , storeTrim = const $ return ()
                      , storeClose = return ()
                      }
                 )
    , persistDirectory  = testPersistDirectory
    , leaseTimeout      = 3000000
    , leaseRenewTimeout = 1000000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= 100)
    , snapshotRestoreTimeout = 1000000
    }

ssdictState :: SerializableDict State
ssdictState = SerializableDict

killOnError :: ProcessId -> Process a -> Process a
killOnError pid p = catch p $ \e -> liftIO (print e) >>
  exit pid (show (e :: SomeException)) >> liftIO (throwIO e)

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

remotable [ 'dictState, 'testLog, 'ssdictState, 'testConfig, 'snapshotServer
          , 'testPersistDirectory
          ]

remotableDecl [ [d|

  consInt :: Int -> State -> Process State
  consInt x = return . (x:)

  readInts :: State -> Process State
  readInts = return

  testReplica :: (ProcessId,Int,RemoteHandle (Command State)) -> Process ()
  testReplica (self,x,rHandle) = killOnError self $ do
    port <- Log.clone rHandle >>= State.newPort :: Process (CommandPort State)
    State.update port $ $(mkClosure 'consInt) x
    newState <- State.select $(mkStatic 'ssdictState)
                  port $(mkStaticClosure 'readInts)
    send self (x,reverse newState)

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
 argv <- getArgs
 let useTCP = case argv of
      ("tcp":_)   -> [mkTCPTransport]
      ("inmem":_) -> [mkInMemoryTransport]
      _           -> [mkTCPTransport, mkInMemoryTransport]
 setEnv "DP_SCHEDULER_ENABLED" "1" True
 if not schedulerIsEnabled
   then putStrLn "The deterministic scheduler is not enabled." >> exitFailure
   else do
     args <- getArgs
     s <- case args of
            "single" : _ -> randomIO
            sstr : _ -> return (read sstr)
            _ -> randomIO
     mapM_ (go args s) useTCP
  where
    go args s open =
         bracket open
                 (closeAbstractTransport)
                 $ \(AbstractTransport transport _ _) -> do
            case args of
              _ : istr : _ -> run transport $ read istr
              _ -> do
                putStrLn $ "Running " ++ show numIterations ++ " random tests..."
                putStrLn $ "initial seed: " ++ show s
                forM_ (take numIterations $ randoms $ mkStdGen s) $ run transport
            putStrLn $ "SUCCESS!"
        where
          numIterations = 20

run :: Transport -> Int -> IO ()
run transport s = brackets 2
  (newLocalNode transport remoteTables)
  closeLocalNode
  $ \nodes@(n0:_) -> withTmpDirectory $ runProcess' n0 $
    withScheduler [] (fst $ random $ mkStdGen s) $ do
    let tries = length nodes
    forM_ nodes $ \n -> spawn (localNodeId n)
                              $(mkStaticClosure 'snapshotServer)
    Log.new $(mkStatic 'State.commandEqDict)
            ($(mkStatic 'State.commandSerializableDict)
               `staticApply` sdictState)
            (staticClosure $(mkStatic 'testConfig))
            (staticClosure $(mkStatic 'testLog))
            (map localNodeId nodes)
    h <- Log.spawnReplicas testLogId
                           $(mkStaticClosure 'testPersistDirectory)
                           (map localNodeId nodes)
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
          -- test that updates are not missed or duplicated
          when (1 /= length (filter (x==) newState)) $
            fail $ "Test failed: update missed or duplicated: "
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
  runProcess n (try (getSelfNode >>= linkNode >> p) >>= liftIO . writeIORef r)
    >> readIORef r
      >>= either (\e -> throwIO (e :: SomeException)) return

brackets :: Int -> IO a -> (a -> IO ()) -> ([a] -> IO b) -> IO b
brackets n c r action = go id n
  where go acc i | i>0 = bracket c r $ \a -> go (acc . (a:)) (i-1)
        go acc _ = action (acc [])
