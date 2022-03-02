-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Test (tests) where

import Test.Framework
import Transport

import Control.Distributed.Process.Consensus ( __remoteTable )
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log.Snapshot
import Control.Distributed.Log.Persistence.Paxos (acceptorStore)
import qualified Control.Distributed.Log.Persistence as P
import Control.Distributed.Log.Persistence.LevelDB
import Control.Distributed.Log
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import qualified Control.Distributed.Log.Policy as Policy
import Control.Distributed.Process.Monitor (retryMonitoring)
import Control.Distributed.Process.Timeout (retry, timeout)

import Control.Distributed.Process hiding (catch, bracket_, bracket, finally)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types (processNode)
import Control.Distributed.Process.Scheduler
import Control.Distributed.Static
import Data.Rank1Dynamic

import Control.Concurrent.MVar
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Reader (ask)
import Data.Constraint (Dict(..))
import Data.Binary (Binary)
import Data.Function (fix)
import Data.List (isPrefixOf)
import Data.Ratio ((%))
import Data.String (fromString)
import Data.Typeable (Typeable)
import System.Directory (renameDirectory)
import System.IO
import System.FilePath ((</>))
import System.Random
import qualified System.Timeout as System

import Prelude hiding (read)
import qualified Prelude


newtype State = State { unState :: Int }
    deriving (Typeable, Binary)

increment :: State -> Process State
increment (State x) = do say "Increment."; return $ State $ x + 1

incrementCP :: CP State State
incrementCP = staticClosure incrementStatic
  where
    incrementStatic :: Static (State -> Process State)
    incrementStatic = staticLabel "Test.increment"

read :: State -> Process Int
read = return . unState

readCP :: CP State Int
readCP = staticClosure readStatic
  where
    readStatic :: Static (State -> Process Int)
    readStatic = staticLabel "Test.read"

dictInt :: SerializableDict Int
dictInt = SerializableDict

dictState :: Dict (Typeable State)
dictState = Dict

snapshotServerLbl :: String
snapshotServerLbl = "snapshot-server"

state0 :: State
state0 = State 0

testLog :: State.Log State
testLog = State.log $ serializableSnapshot snapshotServerLbl state0

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

snapshotThreshold :: Int
snapshotThreshold = 10

testLogId :: Log.LogId
testLogId = Log.toLogId "test-log"

testPersistDirectory :: NodeId -> FilePath
testPersistDirectory = filepath "replicas"

testConfig :: Log.Config
testConfig = Log.Config
    { logId             = testLogId
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

retryLog :: Log.Handle a -> Process (Maybe b) -> Process b
retryLog h = retryMonitoring (Log.monitorLog h) $
               fromIntegral $ Log.leaseTimeout testConfig `div` 2

snapshotServer :: Process ()
snapshotServer = void $ serializableSnapshotServer
                    snapshotServerLbl
                    (filepath "replica-snapshots")

remotable [ 'dictInt, 'dictState, 'testLog, 'testConfig, 'snapshotServer
          , 'testPersistDirectory
          ]

sdictInt :: Static (SerializableDict Int)
sdictInt = $(mkStatic 'dictInt)
  where _ = $(functionSDict 'testPersistDirectory) -- avoids unused warning

sdictState :: Static (Dict (Typeable State))
sdictState = $(mkStatic 'dictState)

cloneHandleIn :: Typeable a
              => Log.Handle a -> LocalNode -> Process (Log.Handle a)
cloneHandleIn h0 node = do
    rh0 <- Log.remoteHandle h0
    self <- getSelfPid
    mv <- liftIO newEmptyMVar
    _ <- liftIO $ forkProcess node $ do
      Log.clone rh0 >>= liftIO . putMVar mv
      when schedulerIsEnabled $ usend self ()
    when schedulerIsEnabled expect
    liftIO $ takeMVar mv

bToM :: Bool -> Maybe ()
bToM True  = Just ()
bToM False = Nothing

remoteTables :: RemoteTable
remoteTables =
  Test.__remoteTable $
  registerStatic "Test.increment" (toDynamic increment) $
  registerStatic "Test.read" (toDynamic read) $
  Control.Distributed.Process.Consensus.__remoteTable $
  Control.Distributed.Process.Scheduler.__remoteTable $
  BasicPaxos.__remoteTable $
  Log.__remoteTable $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

tests :: [String] -> IO [TestTree]
tests argv = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    seed <- randomIO
    when schedulerIsEnabled $
      putStrLn $ "Running with scheduler using " ++ show seed ++
                 " as initial seed."

    let runTest :: Int
                -> Int
                -> Int
                -> Int
                -> Int
                -> (AbstractTransport -> [LocalNode] -> Process ())
                -> IO ()
        runTest s0 clockSpeed _t reps n action
          | schedulerIsEnabled =
              forM_ [1..reps] $ \i ->
                (withTmpDirectory $ withAbstractTransport $
                  \tr@(AbstractTransport transport _ _) ->
                  (>>= maybe (error "Timeout") return) $
                  System.timeout (5 * 60 * 1000000) $
                  withScheduler (s0 + i) clockSpeed n transport remoteTables $
                    \nodes ->
                    do node0 <- fmap processNode ask
                       action tr (node0 : nodes)
                 ) `catch` \e -> do
                    hPutStrLn stderr $ "execution failed with seed " ++
                                       show (s0 + i, i) ++ ": " ++
                                       show (e :: SomeException)
                    throwM e
          | otherwise = withTmpDirectory $ withAbstractTransport $
              \tr@(AbstractTransport transport _ _) ->
                withLocalNodes (n - 1) transport remoteTables $ \nodes ->
                  tryWithTimeout transport remoteTables
                                 (5 * 60 * 1000000) $ do
                     node0 <- fmap processNode ask
                     action tr (node0 : nodes)
        setupSched :: Int
                   -> Int
                   -> Int
                   -> Int
                   -> Int
                   -> Int
                   -> ( [LocalNode] ->
                        [LocalNode] ->
                        Log.Handle (Command State) ->
                        State.CommandPort State ->
                        Process ()
                      )
                   -> IO ()
        setupSched s0 clockSpeed t reps n extras action =
          setupSched' s0 clockSpeed t reps n extras (const action)
        setupSched' s0 clockSpeed t reps n extras action =
          runTest s0 clockSpeed t reps (n + extras) $ \tr nodes ->
            setup' (take n $ map localNodeId nodes)
                   (uncurry (action tr) $ splitAt n nodes)
        withAbstractTransport :: (AbstractTransport -> IO a) -> IO a
        withAbstractTransport =
            bracket (if "--tcp-transport" `elem` argv
                        then mkTCPTransport
                        else mkInMemoryTransport
                      )
                      closeAbstractTransport
        setup' nodes action = do
            let waitFor pid = monitor pid >> receiveWait
                    [ matchIf (\(ProcessMonitorNotification _ pid' _) ->
                                   pid == pid'
                              )
                              $ const $ return ()
                    ]
            bracket (forM nodes $ flip
                      spawn $(mkStaticClosure 'snapshotServer)
                    )
                    (mapM_ $ \pid -> exit pid "setup" >> waitFor pid) $
                    const $
                bracket (do
                            say "Creating group"
                            Log.new
                              $(mkStatic 'State.commandEqDict)
                              ($(mkStatic 'State.commandSerializableDict)
                                 `staticApply` sdictState)
                              (staticClosure $(mkStatic 'testConfig))
                              (staticClosure $(mkStatic 'testLog))
                              nodes
                            say "Spawning replicas"
                            Log.spawnReplicas
                               testLogId
                               $(mkStaticClosure 'testPersistDirectory)
                               nodes
                        )
                        (\h -> forM_ nodes (\n -> Log.killReplica h n))
                        $ \h -> do
                  say "Starting test"
                  State.newPort h >>= action h

    let ut = testGroup "ut"
          [ testSuccess "single-command"
              $ setupSched seed 5000 10000000 20 1 0
              $ \_ _ h port -> do
                retryLog h $ bToM <$> State.update port incrementCP
                assert . (>= 1) =<<
                  retryLog h (State.select sdictInt port readCP)

          , testSuccess "two-command"
              $ setupSched seed 5000 10000000 20 1 0 $
              \_ _ h port -> do
                retryLog h $ bToM <$> State.update port incrementCP
                retryLog h $ bToM <$> State.update port incrementCP
                assert . (>= 2) =<<
                  retryLog h (State.select sdictInt port readCP)

          , testSuccess "clone"
              $ setupSched seed 5000 10000000 20 1 0 $
              \_ _ h _ -> do
                self <- getSelfPid
                rh <- Log.remoteHandle h
                usend self rh
                rh' <- expect
                h' <- Log.clone rh'
                port <- State.newPort h'
                retryLog h $ bToM <$> State.update port incrementCP
                retryLog h $ bToM <$> State.update port incrementCP
                assert . (>= 2) =<<
                  retryLog h (State.select sdictInt port readCP)

          -- , testSuccess "duplicate-command" $ setup $ \h port -> do
          --       port' <- State.newPort h
          --       State.update port  incrementCP
          --       State.update port  incrementCP
          --       State.update port' incrementCP
          --       assert . (== 2) =<< State.select sdictInt port readCP

          , testSuccess "addReplica-start-new-replica" $
              setupSched seed 5000 10000000 20 1 1 $ \_ (node1 : _) h _ -> do
                self <- getSelfPid
                h1 <- cloneHandleIn h node1
                _ <- liftIO $ forkProcess node1 $ do
                  registerInterceptor $ \string ->
                    if "New replica started in legislature://"
                       `isPrefixOf` string
                    then usend self ()
                    else return ()
                  usend self ((), ())
                ((), ()) <- expect

                say "Adding replica."
                _ <- liftIO $ forkProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retryLog h1 $
                      bToM <$> Log.addReplica h1 here
                    usend self ((), ())
                ((), ()) <- expect
                () <- expect
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-new-replica-old-decrees"
              $ setupSched seed 5000 10000000 20 1 1 $ \_ (node1 : _) h port -> do
                self <- getSelfPid
                h1 <- cloneHandleIn h node1
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                _ <- liftIO $ forkProcess node1 $ do
                  registerInterceptor $ interceptor
                  usend self ((), ())
                ((), ()) <- expect

                retryLog h $ bToM <$> State.update port incrementCP
                () <- expect
                say "Existing replica incremented."

                _ <- liftIO $ forkProcess node1 $ do
                  here <- getSelfNode
                  snapshotServer
                  retryLog h1 $ bToM <$> Log.addReplica h1 here
                  usend self ((), ())
                ((), ()) <- expect

                () <- expect
                say "New replica incremented."
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-new-replica-new-decrees"
              $ setupSched seed 1000 10000000 20 1 1 $ \_ (node1 : _) h port -> do
                self <- getSelfPid
                h1 <- cloneHandleIn h node1
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                _ <- liftIO $ forkProcess node1 $ do
                  registerInterceptor $ interceptor
                  usend self ((), ())
                ((), ()) <- expect

                _ <- liftIO $ forkProcess node1 $ do
                  here <- getSelfNode
                  snapshotServer
                  retryLog h1 $ bToM <$> Log.addReplica h1 here
                  usend self ((), ())
                ((), ()) <- expect

                retryLog h $ bToM <$> State.update port incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-idempotent" $
            setupSched seed 5000 10000000 20 1 0 $ \_ _ h port -> do
              here <- getSelfNode

              retryLog h $ bToM <$> State.update port incrementCP

              _ <- retryLog h $ bToM <$> Log.addReplica h here
              retryLog h $ bToM <$> State.update port incrementCP

              i <- retryLog h $ State.select sdictInt port readCP
              assert (i >= 2)
              say "Restarting replicas preserves the state."

          , testSuccess "addReplica-interrupted-idempotent" $
            setupSched seed 5000 10000000 20 1 0 $ \_ _ h port -> do
              here <- getSelfNode

              retryLog h $ bToM <$> State.update port incrementCP

              _ <- retryLog h $ do
                     -- Interrupt the first attempt.
                     _ <- timeout 1000 $ Log.addReplica h here
                     bToM <$> Log.addReplica h here

              retryLog h $ bToM <$> State.update port incrementCP

              i <- retryLog h $ State.select sdictInt port readCP
              assert (i >= 2)
              say $ "Restarting replicas preserves the state even with "
                    ++ "interruptions."

          , testSuccess "new-idempotent" $
              setupSched seed 5000 10000000 20 2 0 $ \[n0, n1] _ h port -> do
                retryLog h $ bToM <$> State.update port incrementCP
                setup' [localNodeId n0, localNodeId n1] $ \h' port' -> do
                  retryLog h' $ bToM <$> State.update port' incrementCP
                  i <- retryLog h' $ State.select sdictInt port' readCP
                  assert (i >= 2)
                  say "Starting a group twice is idempotent."
                  Log.killReplica h' (localNodeId n0)
                  Log.killReplica h' (localNodeId n1)

          , testSuccess "update-handle" $
              setupSched seed 5000 20000000 20 1 2 $ \_ [n, node1] h port -> do
                self <- getSelfPid
                h1 <- cloneHandleIn h node1
                hn <- cloneHandleIn h n
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                _ <- liftIO $ forkProcess node1 $ do
                    registerInterceptor interceptor
                    here <- getSelfNode
                    snapshotServer
                    retryLog h1 $ bToM <$> Log.addReplica h1 here
                    usend self ((), ())
                ((), ()) <- expect

                _ <- liftIO $ forkProcess n $ do
                    registerInterceptor interceptor
                    snapshotServer
                    here <- getSelfNode
                    retryLog hn $ bToM <$> Log.addReplica hn here
                    updateHandle h here
                    usend self ((), ())
                ((), ()) <- expect

                -- Kill the first node, and see that the updated handle
                -- still works. But don't kill it too soon or the new replicas
                -- wont have a chance to replicate its state. We do an update
                -- to ensure the state is replicated.
                retryLog h $ bToM <$> State.update port incrementCP
                () <- expect
                () <- expect
                getSelfNode >>= Log.killReplica h
                retryLog h $ bToM <$> State.update port incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."
                Log.killReplica h (localNodeId n)
                Log.killReplica h (localNodeId node1)

          , testSuccess "quorum-after-remove" $
              setupSched seed 1000 20000000 20 1 2 $
                \_ ns@[node1, node2] h port -> do
                self <- getSelfPid
                hs <- mapM (cloneHandleIn h) ns
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor interceptor
                _ <- liftIO $ forkProcess node1 $ do
                  registerInterceptor interceptor
                  usend self ((), ())
                ((), ()) <- expect
                _ <- liftIO $ forkProcess node2 $ do
                  registerInterceptor interceptor
                  usend self ((), ())
                ((), ()) <- expect

                forM_ (zip [node1, node2] hs) $ \(lnid, hn) -> do
                  _ <- liftIO $ forkProcess lnid $ do
                    snapshotServer
                    retryLog hn $ bToM <$> Log.addReplica hn (localNodeId lnid)
                    usend self ((), ())
                  ((), ()) <- expect
                  return ()

                Log.status h
                -- We do an update to ensure the state is replicated before
                -- proceeding to remove nodes.
                retryLog h $ bToM <$> State.update port incrementCP
                () <- expect
                _ <- expectTimeout 1000000 :: Process (Maybe ())
                _ <- expectTimeout 1000000 :: Process (Maybe ())

                say "Removing a replica ..."
                retryLog h $ bToM <$> Log.removeReplica h (localNodeId node1)
                say "Killing another replica ..."
                Log.killReplica h (localNodeId node2)
                say "Recovering quorum ..."
                here <- getSelfNode
                fix $ \loop -> do
                  b <- Log.recover h [here]
                  if b then return () else loop

                say "Checking quorum ..."
                retryLog h $ bToM <$> State.update port incrementCP
                () <- expect
                say "Still alive replica increments."
                Log.killReplica h (localNodeId node1)

          , testSuccess "log-size-remains-bounded" . withTmpDirectory $
              setupSched seed 1000 60000000 5 1 1 $ \_ [node1] h port -> do
                -- TODO: May possibly fail if some replicas are slow.
                -- The problem is that snapshots could be updated so fast that
                -- a delayed replica can never grab it on time.
                --
                -- This failure is sensitive to the duration of the lease period
                -- and the snapshot threashold used for replicas.
                self <- getSelfPid
                h1 <- cloneHandleIn h node1
                let logSizePfx = "Log size when trimming: "
                    interceptor :: NodeId -> String -> Process ()
                    interceptor _ "Increment." = usend self ()
                    interceptor _ msg@"Trimming log." = usend self msg
                    interceptor nid s | logSizePfx `isPrefixOf` s =
                      usend self ( nid
                                 , Prelude.read $ drop (length logSizePfx) s
                                                 :: Int
                                 )
                    interceptor _ _ = return ()
                getSelfNode >>= registerInterceptor . interceptor

                let incrementCount = snapshotThreshold + 1
                    expectIntFrom :: NodeId -> Process Int
                    expectIntFrom nid = receiveWait
                      [ matchIf ((nid ==) . fst) (return . snd) ]
                logSizes <- replicateM 5 $ do
                  replicateM_ incrementCount $ do
                    retryLog h $ bToM <$> State.update port incrementCP
                    expect :: Process ()
                  receiveWait
                    [ matchIf (\s -> s == "Trimming log.") (const $ return ()) ]
                  getSelfNode >>= expectIntFrom

                say $ show logSizes
                -- The size of the log should account for medieval and modern
                -- history. It is possible to have a log slightly bigger because
                -- it may contain decrees not yet executed.
                assert $ all (<= snapshotThreshold * 3) logSizes
                say "Log size remains bounded with no reconfigurations."

                _ <- liftIO $ forkProcess node1 $ do
                  getSelfNode >>= registerInterceptor . interceptor
                  usend self ((), ())
                ((), ()) <- expect

                _ <- liftIO $ forkProcess node1 $ do
                  here <- getSelfNode
                  snapshotServer
                  retryLog h1 $ bToM <$> Log.addReplica h1 here
                  usend self ((), ())
                ((), ()) <- expect

                logSizes' <- replicateM 5 $ do
                  replicateM_ incrementCount $ do
                    retryLog h $ bToM <$> State.update port incrementCP
                    () <- expect
                    -- We are not interested in the message per-se. We just want
                    -- to slow down the test so the non-leader replica has a
                    -- chance to execute the decrees and keep the log size
                    -- controlled.
                    --
                    -- In addition, we cannot use @expect@ because the
                    -- non-leader replica may not execute the request if it gets
                    -- it as part of a snapshot.
                    void (expectTimeout 1000000 :: Process (Maybe ()))
                  here <- getSelfNode
                  replicateM_ 2 $ receiveWait
                    [ matchIf (\s -> s == "Trimming log.") (const $ return ()) ]
                  liftM2 (,) (expectIntFrom here)
                             (expectIntFrom $ localNodeId node1)

                say $ show logSizes'
                -- The size of the log should account for medieval and modern
                -- history. It is possible to have a log slightly bigger because
                -- it may contain decrees not yet executed.
                --
                -- In addition, the first report of the log size may be bigger
                -- than expected if the new replica is trying to catch-up.
                assert $ all (<= snapshotThreshold * 3)
                             (concatMap (\(a, b) -> [a, b]) $ drop 1 logSizes')
                say "Log size remains bounded after reconfiguration."

                -- Wait a bit before killing the acceptors so they can process
                -- any pending requests to trim the state.
                Nothing <- receiveTimeout 1000000 [] :: Process (Maybe ())

                Log.killReplica h (localNodeId node1)

                here <- getSelfNode
                Log.killReplica h here
                -- Check that the size of the acceptor state is bounded as well.
                forM_ [here, localNodeId node1] $ \n -> bracket
                  (liftIO $ openPersistentStore (filepath "acceptors" n))
                  -- Don't forget to close the handle explicitly or a finalizer
                  -- placed by leveldb-haskell may close it prematurely.
                  (liftIO . P.close) $
                  \ps -> do
                    pm <- liftIO $ P.getMap ps $ fromString "decrees"
                    kvs <- liftIO $
                             P.pairsOfMap (pm :: P.PersistentMap (Int, Int))
                    say $ "Acceptor state after reconfiguration: " ++
                          show (map fst kvs)
                    assert (length kvs <= 2*snapshotThreshold)
                say "Acceptor state remains bounded."

          , testSuccess "quorum-after-transient-failure" $
              setupSched' seed 5000 20000000 20 1 1 $
                \(AbstractTransport _ closeConnection _) _ [node1] h _ -> do
                h1 <- cloneHandleIn h node1
                port1 <- State.newPort h1
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor interceptor
                _ <- liftIO $ forkProcess node1 $ do
                  registerInterceptor interceptor
                  usend self ((), ())
                ((), ()) <- expect

                say "adding replica"
                _ <- liftIO $ forkProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retryLog h1 $ do
                      say "trying adding replica"
                      bToM <$> Log.addReplica h1 here
                    updateHandle h1 here
                    usend self ((), ())
                ((), ()) <- expect

                say "updating state"
                _ <- liftIO $ forkProcess node1 $ do
                  retryLog h1 $ bToM <$> State.update port1 incrementCP
                  usend self ((), ())
                ((), ()) <- expect
                () <- expect
                _ <- expectTimeout 5000000 :: Process (Maybe ())

                -- interrupt the connection between the replicas
                say "interrupting connection"
                here <- getSelfNode
                if schedulerIsEnabled then
                  addFailures [ ((here, localNodeId node1), 1.0)
                              , ((localNodeId node1, here), 1.0)
                              ]
                else
                  liftIO $
                    closeConnection (nodeAddress here)
                                    (nodeAddress $ localNodeId node1)
                _ <- liftIO $ forkProcess node1 $ do
                  -- restore the communication asynchronously
                  self1 <- getSelfPid
                  restorePid <- spawnLocal $ do
                    () <- expect
                    when schedulerIsEnabled $ do
                      say "restoring connection"
                      removeFailures [ (here, localNodeId node1)
                                     , (localNodeId node1, here)
                                     ]
                    usend self1 ()
                  retryLog h1 $ do
                    say "trying update"
                    bToM <$> State.update port1 incrementCP
                   `finally` usend restorePid ()
                  () <- expect
                  usend self ((), ())
                ((), ()) <- expect
                say "expecting first ()"
                () <- expect
                say "expecting second ()"
                _ <- expectTimeout 5000000 :: Process (Maybe ())
                say "Replicas continue to have quorum."
                Log.killReplica h (localNodeId node1)

           , testSuccess "durability" $
               setupSched seed 1000 30000000 20 5 0 $ \nodes _ h port -> do
                 retryLog h $
                   bToM <$> State.update port incrementCP
                 assert . (>= 1) =<<
                   retryLog h (State.select sdictInt port readCP)
                 say "Incremented state from scratch."
                 forM_ (map localNodeId nodes) $ Log.killReplica h

                 setup' (map localNodeId nodes) $ \_ port1 -> do
                   retryLog h $ bToM <$> State.update port1 incrementCP
                   assert . (>= 2) =<<
                     retryLog h (State.select sdictInt port1 readCP)
                   say "Incremented state from disk."

           , testSuccess "recovery" $
               setupSched seed 1000 10000000 20 2 2 $
               \lnodes0 lnodes1 h port -> do
                 let nodes0 = map localNodeId lnodes0
                     nodes1 = map localNodeId lnodes1
                 say $ "Test start: " ++ show (nodes0, nodes1)
                 retryLog h $ bToM <$> State.update port incrementCP
                 assert . (>= 1) =<<
                   retryLog h (State.select sdictInt port readCP)
                 say "Incremented state from scratch."
                 forM_ nodes0 $ Log.killReplica h

                 let persistDirs = map filepath
                       ["replicas", "replica-snapshots", "acceptors"]
                 forM_ (zip nodes0 nodes1) $ \(n0, n1) ->
                   forM_ persistDirs $ \fp ->
                     liftIO $ renameDirectory (fp n0) (fp n1)

                 setup' nodes1 $ \h1 port1 -> do
                   fix $ \loop -> do
                     b <- Log.recover h1 nodes1
                     if b then return () else loop
                   say "Second increment"
                   retryLog h1 $ bToM <$> State.update port1 incrementCP
                   say "Query"
                   assert . (>= 2) =<<
                     retryLog h1 (State.select sdictInt port1 readCP)
                   say "Incremented state from disk."
            ]
        timeoutTests = testGroup "timeout"
            [ testSuccess "timeout-expires" $ runTest seed 1000 10000000 20 1 $
                \_ _ -> do
                Nothing <- timeout 1000 (expect :: Process ())
                return ()

            , testSuccess "timeout-completes" $ runTest seed 1000 10000000 20 1
                $ \_ _ -> do
                Just () <- timeout 1000 (return ())
                return ()

            , testSuccess "retry-completes" $ runTest seed 1000 10000000 20 1
                $ \_ _ -> do
                self <- getSelfPid
                retry 1000 $ do
                  _ <- spawnLocal $ do
                    Nothing <- receiveTimeout 1000 []
                    usend self ()
                  expect

            , testSuccess "retry-can-be-interrupted" $
                runTest seed 1000 10000000 20 1 $ \_ _ -> do
                self <- getSelfPid
                do retry 10000 $ do
                     _ <- spawnLocal $ exit self "test interruption"
                     (expect :: Process ())
                   assert False
                  `catchExit` \_ "test interruption" -> return ()
            ]
    return [ timeoutTests, ut ]
