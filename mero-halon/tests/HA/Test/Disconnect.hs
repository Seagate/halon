-- |
-- Module    : HA.Test.Disconnect
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Various tests exercising the node recovery rule. Note that these
-- tests only check if node manages to rejoin the cluster under
-- various scenarios. Notably, it does not verify if m0d processes are
-- restarted &c.
module HA.Test.Disconnect (tests) where

import           Control.Distributed.Process hiding (bracket_)
import           Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import           Control.Monad
import           Data.Binary (Binary)
import           Data.List
import           Data.Typeable
import           GHC.Generics
import           GHC.Word (Word8)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.RC.Events.Cluster
import           HA.RecoveryCoordinator.Service.Events
import           HA.Replicator.Log (RLogGroup)
import           HA.Resources.HalonVars
import           HA.Service (getInterface)
import           HA.Service.Interface
import qualified HA.Services.Ping as Ping
import           Helper.InitialData
import qualified Helper.Runner as H
import           Network.CEP (subscribe, Published(..))
import           Network.Transport (Transport, EndPointAddress)
import qualified Network.Transport.Controlled as Controlled
import           Test.Framework (registerInterceptor, testGroup, TestTree)
import           Test.Tasty.HUnit (testCase)

tests :: Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> TestTree
tests t breakConnection = testGroup "Disconnect tests"
  [ testCase "testDisconnect" $ testDisconnect t breakConnection
  , testCase "testRejoin" $ testRejoin t breakConnection
  , testCase "testRejoinTimeout" $ testRejoinTimeout t breakConnection
  ]

newtype Dummy = Dummy String
  deriving (Typeable, Generic, Binary)

-- | Tests that tracking station failures allow the cluster to proceed.
--
-- * Start a satellite and three tracking station nodes.
-- * Start the noisy service in the satellite.
-- * Isolate a tracking station node so it cannot communicate with any other node.
-- * Wait for the RC to report events produced by the service.
-- * Re-enable communications of the TS node.
-- * Isolate another TS node.
-- * Wait for the RC to report events produced by the service.
-- * Re-enable communications of the TS node.
-- * Isolate another TS node.
-- * Wait for the RC to report events produced by the service.
testDisconnect :: Transport
               -> (EndPointAddress -> EndPointAddress -> IO ())
               -> IO ()
testDisconnect baseTransport connectionBreak = do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit' transport controlled 4 3 2 $ \ts splitNet restoreNet -> do
    let ts_nids = map localNodeId $ H._ts_ts_nodes ts
        [sat0] = filter (\n -> localNodeId n `notElem` ts_nids) (H._ts_nodes ts)
    -- Assert we have 3 TS as expected
    [_, _, _] <- return ts_nids
    self <- getSelfPid

    -- Assumption: we're running test on RC node
    registerInterceptor $ \string -> do
      let t = "Recovery Coordinator: received DummyEvent "
      case string of
        str' | t `isInfixOf` str' -> usend self $ Dummy (drop (length t) str')
        _ -> return ()
    subscribe (H._ts_rc ts) (Proxy :: Proxy (HAEvent ServiceStarted))

    sayTest "Starting ping service"
    [(pingNid, _)] <- serviceStartOnNodes [processNodeId $ H._ts_rc ts]
                                          Ping.ping Ping.defaultConf
                                          [localNodeId sat0]
    sayTest $ "Running ping"
    runPing pingNid 0
    sayTest $ "Starting isolations"
    forM_ (zip [1 :: Int,3..] ts_nids) $ \(i,m) -> do
      sayTest $ "isolating TS node " ++ (show m)
      splitNet [[m], filter (m /=) ts_nids]
      runPing pingNid i

      sayTest $ "rejoining TS node " ++ (show m)
      restoreNet ts_nids
      runPing pingNid (i + 1)

      sayTest "testDisconnect complete"
  where
    runPing :: NodeId -> Int -> Process ()
    runPing nid i = do
      sendSvc (getInterface Ping.ping) nid $! Ping.DummyEvent (show i)
      receiveWait [ matchIf (\(Dummy str) -> show i == str)
                            (const $ return ()) ]

-- | Tests that:
--  * nodes are timed out when disconnected for long enough
--  * nodes can rejoin after they were timed out
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Wait
-- until RC enters timeout routine. Check that we can rejoin the node
-- explicitly afterwards (such as when user asks to bootstrap
-- satellite).
testRejoinTimeout :: Transport
                  -> (EndPointAddress -> EndPointAddress -> IO ())
                  -> IO ()
testRejoinTimeout baseTransport connectionBreak = do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit' transport controlled 1 0 1 $ \ts splitNet restoreNet -> do
    subscribe (H._ts_rc ts) (Proxy :: Proxy NodeTransient)
    subscribe (H._ts_rc ts) (Proxy :: Proxy NewNodeConnected)
    subscribe (H._ts_rc ts) (Proxy :: Proxy HostDisconnected)

    let [m0] = H._ts_nodes ts
    splitNet [[processNodeId $ H._ts_rc ts], [localNodeId m0]]
    -- ack node down
    _ :: NodeTransient <- expectPublished
    -- wait until timeout happens
    _ :: HostDisconnected <- expectPublished
    -- then bring it back up
    restoreNet [processNodeId $ H._ts_rc ts, localNodeId m0]
    -- and make bring it back up
    _ <- emptyMailbox (Proxy :: Proxy (Published NewNodeConnected))
    -- explicitly rejoin as if the user requested it
    void . liftIO . forkProcess m0 $ do
      nodeUp [processNodeId $ H._ts_rc ts]
    _ :: NewNodeConnected <- expectPublished
    sayTest "testRejoinTimeout complete"

-- | Tests that:
-- * The RC detects when a node disconnects.
-- * Nodes can rejoin before we time them out and mark as down.
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Wait until RC
-- detects the node is disconnected. Reconnect the node. Check that RC marks the
-- node as online again.
testRejoin :: Transport
           -> (EndPointAddress -> EndPointAddress -> IO ())
           -> IO ()
testRejoin baseTransport connectionBreak = do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit' transport controlled 1 0 3 $ \ts splitNet restoreNet -> do
    let [sat0] = H._ts_nodes ts

    subscribe (H._ts_rc ts) (Proxy :: Proxy NodeTransient)
    subscribe (H._ts_rc ts) (Proxy :: Proxy RecoveryAttempt)
    subscribe (H._ts_rc ts) (Proxy :: Proxy OldNodeRevival)

    sayTest $ "isolating node " ++ show [localNodeId sat0]
    splitNet [[processNodeId $ H._ts_rc ts], [localNodeId sat0]]
    -- ack node down
    _ :: NodeTransient <- expectPublished
    -- Wait until recovery starts
    _ :: RecoveryAttempt <- expectPublished
    -- Bring one node back up straight away…
    restoreNet [processNodeId $ H._ts_rc ts, localNodeId sat0]
    -- …which gives us a revival of it, swallow recovery messages
    -- until the node comes back up
    _ :: OldNodeRevival <- expectPublished

    sayTest "testRejoin complete"

testSplit' :: Transport
           -> Controlled.Controlled
           -- ^ Transport and controller object.
           -> Word8
           -- ^ Number of nodes to create.
           -> Word8
           -- ^ Number of tracking stations to spawn.
           -> Int
           -- ^ Number of times to run (for scheduler only)
           -> (  H.TestSetup
                 -- ^ List of replica nodes.
              -> ([[NodeId]] -> Process ())
                 -- ^ Callback that splits network between nodes in groups.
              -> ([NodeId] -> Process ())
                 -- ^ Restores communication among the nodes.
              -> Process ()
              )
           -> IO ()
testSplit' transport t amountOfReplicas amountOfTS runs action = do
  isettings <- defaultInitialDataSettings
  tos <- H.mkDefaultTestOptions
  idata <- initialData $ isettings { _id_servers = amountOfReplicas }
  let tos' = tos { H._to_initial_data = idata
                 , H._to_scheduler_runs = runs
                 , H._to_run_decision_log = False
                 , H._to_run_sspl = False
                 , H._to_ts_nodes = amountOfTS
                 , H._to_modify_halon_vars = \vs ->
                     vs { _hv_recovery_expiry_seconds = 5
                        , _hv_recovery_max_retries = 3 }
                 }
      pg = Proxy :: Proxy RLogGroup
  H.run' transport pg [] tos' $ \ts -> action ts doSplit doRestore
  where
    doSplit nds =
      (if Scheduler.schedulerIsEnabled
         then Scheduler.addFailures . concat .
              map (\(a, b) -> [((a, b), 1.0), ((b, a), 1.0)])
         else liftIO . sequence_ .
              map (\(a, b) -> Controlled.silenceBetween t (nodeAddress a)
                                                          (nodeAddress b)
                  )
      )
      [ (a, b) | a <- concat nds, x <- nds, notElem a x, b <- x ]
    doRestore nds =
      (if Scheduler.schedulerIsEnabled
         then Scheduler.removeFailures
         else liftIO . sequence_ .
              map (\(a, b) -> Controlled.unsilence t (nodeAddress a)
                                                     (nodeAddress b)
                  )
      )
      [ (a, b) | a <- nds, b <- nds ]
