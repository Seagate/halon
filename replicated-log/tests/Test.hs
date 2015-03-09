-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
module Test (tests) where

import Test.Framework

import Control.Distributed.Process.Consensus
    ( __remoteTable )
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log.Snapshot
import Control.Distributed.Log ( updateHandle )
import qualified Control.Distributed.State as State
import Control.Distributed.State
    ( Command
    , commandEqDict__static
    , commandSerializableDict__static )
import qualified Control.Distributed.Log.Policy as Policy
import Control.Distributed.Process.Timeout (retry, timeout)

import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler
    ( withScheduler, __remoteTable )
import Control.Distributed.Static
import Data.Rank1Dynamic
import qualified Network.Socket as N (close)
import Network.Transport.TCP

import Control.Monad (forM, forM_, replicateM, replicateM_, void, liftM2)
import Data.Constraint (Dict(..))
import Data.Binary (Binary)
import Data.List (isPrefixOf)
import Data.Ratio ((%))
import Data.Typeable (Typeable)
import System.IO
import System.FilePath ((</>))

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

snapshotThreashold :: Int
snapshotThreashold = 5

testConfig :: Log.Config
testConfig = Log.Config
    { logName           = "test-log"
    , consensusProtocol = \dict -> BasicPaxos.protocol dict 1000000
                                                       (filepath "acceptors")
    , persistDirectory  = filepath "replicas"
    , leaseTimeout      = 1000000
    , leaseRenewTimeout = 300000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreashold)
    , snapshotRestoreTimeout = 1000000
    }

retryTimeout :: Int
retryTimeout = fromIntegral $ Log.leaseTimeout testConfig

snapshotServer :: Process ()
snapshotServer = void $ serializableSnapshotServer
                    snapshotServerLbl
                    (filepath "replica-snapshots")
                    state0

remotable [ 'dictInt, 'dictState, 'testLog, 'testConfig, 'snapshotServer ]

sdictInt :: Static (SerializableDict Int)
sdictInt = $(mkStatic 'dictInt)

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
  Log.__remoteTableDecl $
  Policy.__remoteTable $
  State.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

tests :: [String] -> IO TestTree
tests _ = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    Right (transport, internals) <- createTransportExposeInternals
        "127.0.0.1" "8080" defaultTCPParameters
    putStrLn "Transport created."

    let setup :: Int                      -- ^ Number of nodes to spawn group on.
              -> (Log.Handle (Command State) -> State.CommandPort State -> Process ())
              -> IO ()
        setup = setupTimeout 10000000
        setupTimeout t num action = tryWithTimeout transport remoteTables t $ do
            node0 <- getSelfNode
            nodes <- replicateM (num - 1) $ liftIO $ newLocalNode transport remoteTables
            setup' (node0 : map localNodeId nodes) action
        setup' nodes action =
            withScheduler [] 1 $ do
              say $ "Spawning group."
              bracket (forM nodes $ flip
                         spawn $(mkStaticClosure 'snapshotServer)
                      )
                      (mapM_ (flip exit "setup")) $ const $
                bracket (Log.new $(mkStatic 'State.commandEqDict)
                             ($(mkStatic 'State.commandSerializableDict)
                                `staticApply` sdictState)
                             (staticClosure $(mkStatic 'testConfig))
                             (staticClosure $(mkStatic 'testLog))
                             nodes
                        )
                        (forM_ nodes . Log.killReplica)
                        $ \h ->
                  State.newPort h >>= action h

    let ut = testGroup "ut"
          [ testSuccess "single-command" . withTmpDirectory $ setup 1 $ \_ port -> do
                retry retryTimeout $
                  State.update port incrementCP
                assert . (>= 1) =<<
                  retry retryTimeout (State.select sdictInt port readCP)

          , testSuccess "two-command" . withTmpDirectory    $ setup 1 $ \_ port -> do
                retry retryTimeout $
                  State.update port incrementCP
                retry retryTimeout $
                  State.update port incrementCP
                assert . (>= 2) =<<
                  retry retryTimeout (State.select sdictInt port readCP)

          , testSuccess "clone" . withTmpDirectory          $ setup 1 $ \h _ -> do
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

          , testSuccess "addReplica-start-new-replica" . withTmpDirectory $ setup 1 $ \h _ -> do
                self <- getSelfPid
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ registerInterceptor $ \string ->
                  if "New replica started in legislature://" `isPrefixOf` string
                    then usend self ()
                    else return ()

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h here
                () <- expect
                say "New replica added."
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-new-replica-old-decrees" . withTmpDirectory $ setup 1 $ \h port -> do
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ registerInterceptor $ interceptor

                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                say "Existing replica incremented."

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h here
                () <- expect
                say "New replica incremented."
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-new-replica-new-decrees" . withTmpDirectory $ setup 1 $ \h port -> do
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ registerInterceptor $ interceptor

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h here

                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."
                Log.killReplica h (localNodeId node1)

          , testSuccess "addReplica-idempotent" . withTmpDirectory $
            setup 1 $ \h port -> do
              here <- getSelfNode

              retry retryTimeout $ State.update port incrementCP

              _ <- retry retryTimeout $ Log.addReplica h here
              retry retryTimeout $ State.update port incrementCP

              i <- retry retryTimeout $ State.select sdictInt port readCP
              assert (i >= 2)
              say "Restarting replicas preserves the state."

          , testSuccess "addReplica-interrupted-idempotent" . withTmpDirectory $
            setup 1 $ \h port -> do
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

          , testSuccess "new-idempotent" . withTmpDirectory $ do
              n0 <- newLocalNode transport remoteTables
              n1 <- newLocalNode transport remoteTables
              tryWithTimeout transport remoteTables 5000000
                  $ setup' [localNodeId n0, localNodeId n1] $ \h port -> do
                retry retryTimeout $ State.update port incrementCP
                setup' [localNodeId n0, localNodeId n1] $ \_ port' -> do
                  retry retryTimeout $ State.update port' incrementCP
                  i <- retry retryTimeout $ State.select sdictInt port' readCP
                  assert (i >= 2)
                  say "Starting a group twice is idempotent."
                  Log.killReplica h (localNodeId n0)
                  Log.killReplica h (localNodeId n1)

          , testSuccess "update-handle" . withTmpDirectory $ do
              n <- newLocalNode transport remoteTables
              tryWithTimeout transport remoteTables 20000000
                  $ setup' [localNodeId n] $ \h port -> do
                self <- getSelfPid
                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ do
                    registerInterceptor $ interceptor
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h here

                here <- getSelfNode
                snapshotServer
                retry retryTimeout $
                  Log.addReplica h here
                updateHandle h here

                -- Kill the first node, and see that the updated handle
                -- still works. But don't kill it too soon or the new replicas
                -- wont have a chance to replicate its state. We do an update
                -- to ensure the state is replicated.
                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                () <- expect
                Log.killReplica h $ localNodeId n
                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                () <- expect
                say "Both replicas incremented again after membership change."
                Log.killReplica h (localNodeId node1)
                Log.killReplica h here

          , testSuccess "quorum-after-remove" . withTmpDirectory $
              setupTimeout 20000000 1 $ \h port -> do
                self <- getSelfPid
                node1 <- liftIO $ newLocalNode transport remoteTables
                node2 <- liftIO $ newLocalNode transport remoteTables

                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor $ interceptor
                liftIO $ runProcess node1 $ registerInterceptor $ interceptor
                liftIO $ runProcess node2 $ registerInterceptor $ interceptor

                forM_ [node1, node2] $ \lnid -> liftIO $ runProcess lnid $ do
                  snapshotServer
                  retry retryTimeout $
                    void $ Log.addReplica h (localNodeId lnid)

                Log.status h
                -- We do an update to ensure the state is replicated before
                -- proceeding to remove nodes.
                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                _ <- expectTimeout 1000000 :: Process (Maybe ())
                _ <- expectTimeout 1000000 :: Process (Maybe ())

                forM_ [node1, node2] $ \lnid ->
                  retry retryTimeout $
                    Log.removeReplica h (localNodeId lnid)

                retry retryTimeout $
                  State.update port incrementCP
                () <- expect
                say "Still alive replica increments."
                Log.killReplica h (localNodeId node1)
                Log.killReplica h (localNodeId node2)

          , testSuccess "log-size-remains-bounded" . withTmpDirectory $
              setupTimeout 60000000 1 $ \h port -> do
                self <- getSelfPid
                let logSizePfx = "Log size when trimming: "
                    interceptor :: String -> Process ()
                    interceptor "Increment." = usend self ()
                    interceptor s | logSizePfx `isPrefixOf` s =
                      usend self ( Prelude.read $ drop (length logSizePfx) s
                                                 :: Int
                                )
                    interceptor _ = return ()
                registerInterceptor interceptor

                let incrementCount = snapshotThreashold + 1
                logSizes <- replicateM 5 $ do
                  replicateM_ incrementCount $ do
                    retry retryTimeout $
                      State.update port incrementCP
                    expect :: Process ()
                  expect :: Process Int

                say $ show logSizes
                -- The size of the log should account for medieval and modern
                -- history. It is possible to have a log slightly bigger because
                -- it may contain decrees not yet executed.
                assert $ all (<= snapshotThreashold * 3) logSizes
                say "Log size remains bounded with no reconfigurations."

                node1 <- liftIO $ newLocalNode transport remoteTables
                liftIO $ runProcess node1 $ registerInterceptor interceptor

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      void $ Log.addReplica h here

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
                  liftM2 (,) (expect :: Process Int) (expect :: Process Int)

                say $ show logSizes'
                -- The size of the log should account for medieval and modern
                -- history. It is possible to have a log slightly bigger because
                -- it may contain decrees not yet executed.
                assert $ all (<= snapshotThreashold * 3)
                             (uncurry (++) $ unzip logSizes')
                say "Log size remains bounded after reconfiguration."
                Log.killReplica h (localNodeId node1)

          , testSuccess "quorum-after-transient-failure" . withTmpDirectory $
              setup 1 $ \h port -> do
                self <- getSelfPid
                node1 <- liftIO $ newLocalNode transport remoteTables

                let interceptor "Increment." = usend self ()
                    interceptor _ = return ()
                registerInterceptor interceptor
                liftIO $ runProcess node1 $ registerInterceptor interceptor

                liftIO $ runProcess node1 $ do
                    here <- getSelfNode
                    snapshotServer
                    retry retryTimeout $
                      Log.addReplica h here
                    updateHandle h here

                liftIO $ runProcess node1 $
                  retry retryTimeout $
                    State.update port incrementCP
                () <- expect
                _ <- expectTimeout 5000000 :: Process (Maybe ())

                -- interrupt the connection between the replicas
                here <- getSelfNode
                liftIO $ do
                  socketBetween internals
                                (nodeAddress here)
                                (nodeAddress $ localNodeId node1)
                    >>= N.close
                  socketBetween internals
                                (nodeAddress $ localNodeId node1)
                                (nodeAddress here)
                    >>= N.close

                liftIO $ runProcess node1 $
                  retry retryTimeout $
                    State.update port incrementCP
                () <- expect
                _ <- expectTimeout 5000000 :: Process (Maybe ())
                say "Replicas continue to have quorum."
                Log.killReplica h (localNodeId node1)

           , testSuccess "durability" . withTmpDirectory $ do
               nodes <- replicateM 5 $ fmap localNodeId $
                          newLocalNode transport remoteTables
               tryWithTimeout transport remoteTables 30000000 $ do

                 setup' nodes $ \_ port -> do
                   retry retryTimeout $
                     State.update port incrementCP
                   assert . (>= 1) =<<
                     retry retryTimeout (State.select sdictInt port readCP)
                   say "Incremented state from scratch."

                 setup' nodes $ \_ port -> do
                   retry retryTimeout $
                     State.update port incrementCP
                   assert . (>= 2) =<<
                     retry retryTimeout (State.select sdictInt port readCP)
                   say "Incremented state from disk."
           ]

    return $ testGroup "replicated-log" [ut]
