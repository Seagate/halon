-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
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
import Control.Distributed.Log ( updateHandle )
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import qualified Control.Distributed.Log.Policy as Policy
import Control.Distributed.Process.Timeout (retry, timeout)

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types (processNode)
import Control.Distributed.Process.Scheduler
import Control.Distributed.Static
import Data.Rank1Dynamic
import Network.Transport (Transport)

import qualified Control.Exception as E (bracket, catch)
import Control.Exception as E (SomeException, throwIO)
import Control.Monad
import Control.Monad.Reader (ask)
import Data.Constraint (Dict(..))
import Data.Binary (Binary)
import Data.List (isPrefixOf)
import Data.Ratio ((%))
import Data.String (fromString)
import Data.Typeable (Typeable, Proxy(..))
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

retryTimeout :: Int
retryTimeout = fromIntegral $ Log.leaseTimeout testConfig `div` 2

snapshotServer :: Process ()
snapshotServer = void $ serializableSnapshotServer
                    snapshotServerLbl
                    (filepath "replica-snapshots")
                    (Proxy :: Proxy State)

remotable [ 'dictInt, 'dictState, 'testLog, 'testConfig, 'snapshotServer
          , 'testPersistDirectory
          ]

sdictInt :: Static (SerializableDict Int)
sdictInt = $(mkStatic 'dictInt)
  where _ = $(functionSDict 'testPersistDirectory) -- avoids unused warning

sdictState :: Static (Dict (Typeable State))
sdictState = $(mkStatic 'dictState)

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

    let setupSched :: Int
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
        setupSched' s0 clockSpeed t reps n extras action
          | schedulerIsEnabled =
              forM_ [1..reps] $ \i ->
                withTmpDirectory $ withAbstractTransport $ \tr ->
                  (setupTimeoutSched tr (s0 + i) clockSpeed t n
                                     extras (action tr)
                  ) `E.catch` \e -> do
                    hPutStrLn stderr $ "execution failed with seed " ++
                                       show (s0 + i) ++ ": " ++
                                       show (e :: SomeException)
                    throwIO e
          | otherwise = withTmpDirectory $ withAbstractTransport $
              \tr@(AbstractTransport transport _ _) ->
                withLocalNodes (n - 1 + extras) transport remoteTables $
                  \nodes -> do
                    tryWithTimeout transport remoteTables t $ do
                      node0 <- fmap processNode ask
                      setup' (take n $ map localNodeId $ node0 : nodes) $
                        uncurry (action tr) $ splitAt n (node0 : nodes)
        withAbstractTransport :: (AbstractTransport -> IO a) -> IO a
        withAbstractTransport =
            E.bracket (if "--tcp-transport" `elem` argv
                        then mkTCPTransport
                        else mkInMemoryTransport
                      )
                      closeAbstractTransport
        setupTimeoutSched (AbstractTransport transport _ _) s clockSpeed t num
                          extra action =
          (>>= maybe (error "Timeout") return) $ System.timeout t $
            withScheduler s clockSpeed (num + extra) transport remoteTables $
              \nodes -> do
                node0 <- fmap processNode ask
                setup' (take num $ map localNodeId $ node0 : nodes)
                       (uncurry action $ splitAt num $ node0 : nodes)
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
              $ setupSched seed 10000 10000000 20 1 0
              $ \_ _ _ port -> do
                retry retryTimeout $
                  State.update port incrementCP
                assert . (>= 1) =<<
                  retry retryTimeout (State.select sdictInt port readCP)

          , testSuccess "two-command"
              $ setupSched seed 10000 10000000 20 1 0 $
              \_ _ _ port -> do
                retry retryTimeout $
                  State.update port incrementCP
                retry retryTimeout $
                  State.update port incrementCP
                assert . (>= 2) =<<
                  retry retryTimeout (State.select sdictInt port readCP)

          , testSuccess "clone"
              $ setupSched seed 10000 10000000 20 1 0 $
              \_ _ h _ -> do
                self <- getSelfPid
                rh <- Log.remoteHandle h
                usend self rh
                rh' <- expect
                h' <- Log.clone rh'
                port <- State.newPort h'
                retry retryTimeout $
                  State.update port incrementCP
                retry retryTimeout $
                  State.update port incrementCP
                assert . (>= 2) =<<
                  retry retryTimeout (State.select sdictInt port readCP)

          -- , testSuccess "duplicate-command" $ setup $ \h port -> do
          --       port' <- State.newPort h
          --       State.update port  incrementCP
          --       State.update port  incrementCP
          --       State.update port' incrementCP
          --       assert . (== 2) =<< State.select sdictInt port readCP

          , testSuccess "addReplica-start-new-replica" $
              setupSched seed 8000 10000000 20 1 1 $ \_ (node1 : _) h _ -> do
                self <- getSelfPid
                _ <- liftIO $ forkProcess node1 $ do
                  registerInterceptor $ \string ->
                    if "New replica started in legislature://"
                       `isPrefixOf` string
                    then usend self ()
                    else return ()
                  usend self ((), ())
                ((), ()) <- expect

                _ <- liftIO $ forkProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h here
                    usend self ((), ())
                ((), ()) <- expect
                () <- expect
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-new-replica-old-decrees"
              $ setupSched seed 7100 10000000 20 1 1 $ \_ (node1 : _) h port -> do
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                _ <- liftIO $ forkProcess node1 $ do
                  registerInterceptor $ interceptor
                  usend self ((), ())
                ((), ()) <- expect

                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                say "Existing replica incremented."

                _ <- liftIO $ forkProcess node1 $ do
                  here <- getSelfNode
                  snapshotServer
                  retry retryTimeout $
                    void $ Log.addReplica h here
                  usend self ((), ())
                ((), ()) <- expect

                () <- expect
                say "New replica incremented."
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-new-replica-new-decrees"
              $ setupSched seed 1000 10000000 20 1 1 $ \_ (node1 : _) h port -> do
                self <- getSelfPid
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
                  retry retryTimeout $
                    void $ Log.addReplica h here
                  usend self ((), ())
                ((), ()) <- expect

                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-idempotent" $
            setupSched seed 9000 10000000 20 1 0 $ \_ _ h port -> do
              here <- getSelfNode

              retry retryTimeout $ State.update port incrementCP

              _ <- retry retryTimeout $ Log.addReplica h here
              retry retryTimeout $ State.update port incrementCP

              i <- retry retryTimeout $ State.select sdictInt port readCP
              assert (i >= 2)
              say "Restarting replicas preserves the state."

          , testSuccess "addReplica-interrupted-idempotent" $
            setupSched seed 5000 10000000 20 1 0 $ \_ _ h port -> do
              here <- getSelfNode

              retry retryTimeout $ State.update port incrementCP

              _ <- retry retryTimeout $ do
                     -- Interrupt the first attempt.
                     _ <- timeout 1000 $ Log.addReplica h here
                     Log.addReplica h here

              retry retryTimeout $ State.update port incrementCP

              i <- retry retryTimeout $ State.select sdictInt port readCP
              assert (i >= 2)
              say $ "Restarting replicas preserves the state even with "
                    ++ "interruptions."

          , testSuccess "new-idempotent" $
              setupSched seed 5000 10000000 20 2 0 $ \[n0, n1] _ h port -> do
                retry retryTimeout $ State.update port incrementCP
                setup' [localNodeId n0, localNodeId n1] $ \_ port' -> do
                  retry retryTimeout $ State.update port' incrementCP
                  i <- retry retryTimeout $ State.select sdictInt port' readCP
                  assert (i >= 2)
                  say "Starting a group twice is idempotent."
                  Log.killReplica h (localNodeId n0)
                  Log.killReplica h (localNodeId n1)

          , testSuccess "update-handle" $
              setupSched seed 5000 20000000 20 1 2 $ \_ [n, node1] h port -> do
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                _ <- liftIO $ forkProcess node1 $ do
                    registerInterceptor interceptor
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h here
                    usend self ((), ())
                ((), ()) <- expect

                _ <- liftIO $ forkProcess n $ do
                    registerInterceptor interceptor
                    snapshotServer
                    here <- getSelfNode
                    retry retryTimeout $
                      Log.addReplica h here
                    updateHandle h here
                    usend self ((), ())
                ((), ()) <- expect

                -- Kill the first node, and see that the updated handle
                -- still works. But don't kill it too soon or the new replicas
                -- wont have a chance to replicate its state. We do an update
                -- to ensure the state is replicated.
                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                () <- expect
                getSelfNode >>= Log.killReplica h
                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."
                Log.killReplica h (localNodeId n)
                Log.killReplica h (localNodeId node1)

          , testSuccess "quorum-after-remove" $
              setupSched seed 5000 20000000 20 1 2 $
                \_ [node1, node2] h port -> do
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor interceptor
                liftIO $ runProcess node1 $ registerInterceptor interceptor
                liftIO $ runProcess node2 $ registerInterceptor interceptor

                forM_ [node1, node2] $ \lnid -> do
                  _ <- liftIO $ forkProcess lnid $ do
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h (localNodeId lnid)
                    usend self ((), ())
                  ((), ()) <- expect
                  return ()

                Log.status h
                -- We do an update to ensure the state is replicated before
                -- proceeding to remove nodes.
                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                _ <- expectTimeout 1000000 :: Process (Maybe ())
                _ <- expectTimeout 1000000 :: Process (Maybe ())

                say "Removing a replica ..."
                retry retryTimeout $ Log.removeReplica h (localNodeId node1)
                say "Killing another replica ..."
                retry retryTimeout $ Log.killReplica h (localNodeId node2)
                say "Recovering quorum ..."
                here <- getSelfNode
                retry retryTimeout $ Log.recover h [here]

                say "Checking quorum ..."
                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                say "Still alive replica increments."
                Log.killReplica h (localNodeId node1)
                Log.killReplica h (localNodeId node2)

          , testSuccess "log-size-remains-bounded" . withTmpDirectory $
              setupSched seed 5000 60000000 5 1 1 $ \_ [node1] h port -> do
                -- TODO: May possibly fail if some replicas are slow.
                -- The problem is that snapshots could be updated so fast that
                -- a delayed replica can never grab it on time.
                --
                -- This failure is sensitive to the duration of the lease period
                -- and the snapshot threashold used for replicas.
                self <- getSelfPid
                let logSizePfx = "Log size when trimming: "
                    interceptor :: NodeId -> String -> Process ()
                    interceptor _ "Increment." = usend self ()
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
                    retry retryTimeout $
                      State.update port incrementCP
                    expect :: Process ()
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
                  retry retryTimeout $
                    void $ Log.addReplica h here
                  usend self ((), ())
                ((), ()) <- expect

                logSizes' <- replicateM 5 $ do
                  replicateM_ incrementCount $ do
                    retry retryTimeout $
                      State.update port incrementCP
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
                \(AbstractTransport _ closeConnection _) _ [node1] h port -> do
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor interceptor
                liftIO $ runProcess node1 $ registerInterceptor interceptor

                say "adding replica"
                _ <- liftIO $ forkProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $ do
                      say "trying adding replica"
                      Log.addReplica h here
                    updateHandle h here
                    usend self ((), ())
                ((), ()) <- expect

                say "updating state"
                _ <- liftIO $ forkProcess node1 $ do
                  retry retryTimeout $
                    State.update port incrementCP
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
                      removeFailures [ (here, localNodeId node1)
                                     , (localNodeId node1, here)
                                     ]
                    usend self1 ()
                  retry retryTimeout $ do
                    say "trying update"
                    State.update port incrementCP `finally` usend restorePid ()
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
               setupSched seed 5000 30000000 20 5 0 $ \nodes _ h port -> do
                 retry retryTimeout $
                   State.update port incrementCP
                 assert . (>= 1) =<<
                   retry retryTimeout (State.select sdictInt port readCP)
                 say "Incremented state from scratch."
                 forM_ (map localNodeId nodes) $ Log.killReplica h

                 setup' (map localNodeId nodes) $ \_ port1 -> do
                   retry retryTimeout $
                     State.update port1 incrementCP
                   assert . (>= 2) =<<
                     retry retryTimeout (State.select sdictInt port1 readCP)
                   say "Incremented state from disk."

           , testSuccess "recovery" $
               setupSched seed 5000 10000000 20 2 2 $
               \lnodes0 lnodes1 h port -> do
                 let nodes0 = map localNodeId lnodes0
                     nodes1 = map localNodeId lnodes1
                 retry retryTimeout $
                   State.update port incrementCP
                 assert . (>= 1) =<<
                   retry retryTimeout (State.select sdictInt port readCP)
                 say "Incremented state from scratch."
                 forM_ nodes0 $ Log.killReplica h

                 let persistDirs = map filepath
                       ["replicas", "replica-snapshots", "acceptors"]
                 forM_ (zip nodes0 nodes1) $ \(n0, n1) ->
                   forM_ persistDirs $ \fp ->
                     liftIO $ renameDirectory (fp n0) (fp n1)

                 setup' nodes1 $ \h1 port1 -> do
                   retry retryTimeout $ do
                     Log.recover h1 nodes1
                   say "Second increment"
                   retry retryTimeout $
                     State.update port1 incrementCP
                   say "Query"
                   assert . (>= 2) =<<
                     retry retryTimeout (State.select sdictInt port1 readCP)
                   say "Incremented state from disk."
            ]

    return [ut]

withLocalNodes :: Int -> Transport -> RemoteTable -> ([LocalNode] -> IO a)
               -> IO a
withLocalNodes n t rt action = go [] 0
  where
    go acc i | i == n = action acc
             | otherwise = E.bracket (newLocalNode t rt) closeLocalNode $ \ln ->
                             go (ln : acc) (i + 1)
