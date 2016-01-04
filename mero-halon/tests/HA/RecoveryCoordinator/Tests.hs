{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013-2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module contains a collection of tests that test the RC
-- behaviour: for example service services.
--
-- Tests that do this but depend on USE_MERO to function should go
-- into "HA.RecoveryCoordinator.Mero.Tests".
module HA.RecoveryCoordinator.Tests
  ( testServiceRestarting
  , testServiceNotRestarting
  , testEQTrimming
  , testEQTrimUnknown
  , testClusterStatus
  , testDecisionLog
  , testServiceStopped
  , testMonitorManagement
  , testMasterMonitorManagement
  , testNodeUpRace
  , tests
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types (nullProcessId)
import           Control.Distributed.Process.Node
import           Control.Monad (void)
import           Data.Binary
import           Data.Defaultable
import           Data.List (isInfixOf)
import           Data.Typeable
import           GHC.Generics
import           HA.EQTracker
import           HA.EventQueue
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Service
  ( Service(..)
  , ServiceFailed(..)
  , ServiceProcess(..)
  , ServiceStart(..)
  , ServiceStartRequest(..)
  , ServiceStopRequest(..)
  , ServiceStarted(..)
  , ServiceStartedMsg
  , encodeP
  , runningService
  )
import qualified HA.Services.DecisionLog as DLog
import qualified HA.Services.Dummy as Dummy
import           HA.Services.Monitor
import qualified HA.Services.Monitor as Monitor
import           Network.CEP (defineSimple, liftProcess, subscribe, Definitions , Published(..), Logs(..))
import           Network.Transport (Transport)
import           Prelude hiding ((<$>), (<*>))
import           Test.Framework
import           Test.Tasty.HUnit (testCase)
import           TestRunner

tests :: Transport -> [TestTree]
tests transport =
  [ testCase "testServiceRestarting" $ testServiceRestarting transport
  , testCase "testServiceNotRestarting" $ testServiceNotRestarting transport
  , testCase "testEQTrimming" $ testEQTrimming transport
  , testCase "testEQTrimUnknown" $ testEQTrimUnknown transport
  , testCase "testClusterStatus" $ testClusterStatus transport
  , testCase "testDecisionLog" $ testDecisionLog transport
  , testCase "testServiceStopped" $ testServiceStopped transport
  , testCase "testMonitorManagement" $ testMonitorManagement transport
  , testCase "testMasterMonitorManagement" $ testMasterMonitorManagement transport
  , testCase "testNodeUpRace" $ testNodeUpRace transport
  ]

-- | Test that the recovery co-ordinator can successfully restart a service
--   upon notification of failure.
--   This test does not verify the appropriate detection of service failure,
--   nor does it verify that the 'one service instance per node' constraint
--   is not violated.
testServiceRestarting :: Transport -> IO ()
testServiceRestarting transport = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid
  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      _ -> return ()

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    _ <- promulgateEQ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    "Starting service dummy" :: String <- expect
    say $ "dummy service started successfully."

    pid <- getServiceProcessPid mm (Node nid) Dummy.dummy
    _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy
                                                      pid
    "Starting service dummy" :: String <- expect
    say $ "dummy service restarted successfully."

-- | This test verifies that no service is killed when we send a `ServiceFailed`
--   With a wrong `ProcessId`
testServiceNotRestarting :: Transport -> IO ()
testServiceNotRestarting transport = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      _ -> return ()

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    _ <- promulgateEQ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    "Starting service dummy" :: String <- expect
    say $ "dummy service started successfully."

    -- Assert the service has been started
    _ <- getServiceProcessPid mm (Node nid) Dummy.dummy
    _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy self

    True <- serviceProcessStillAlive mm (Node nid) Dummy.dummy
    say $ "dummy service hasn't been killed."


-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimming :: Transport -> IO ()
testEQTrimming transport = runDefaultTest transport $ do
  nid <- getSelfNode

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs eq mm _) -> do
    nodeUp ([nid], 1000000)
    subscribe eq (Proxy :: Proxy TrimDone)
    Published (TrimDone _) _ <- expect
    _ <- promulgateEQ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    Published (TrimDone _) _ <- expect

    pid <- getServiceProcessPid mm (Node nid) Dummy.dummy
    _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy
                                                      pid

    Published (TrimDone _) _ <- expect
    say $ "Everything got trimmed"

-- | Used by 'testEQTrimUnknown'
data AbraCadabra = AbraCadabra deriving (Typeable, Generic)
instance Binary AbraCadabra


-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimUnknown :: Transport -> IO ()
testEQTrimUnknown transport = runDefaultTest transport $ do
  nid <- getSelfNode

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs eq _ _) -> do
    subscribe eq (Proxy :: Proxy TrimUnknown)
    nodeUp ([nid], 1000000)
    _ <- promulgateEQ [nid] AbraCadabra
    Published (TrimUnknown _) _ <- expect
    say $ "Everything got trimmed"


-- | Message used by 'testClusterStatus'.
data MsgClusterStatus = ClusterSet ClusterStatus
                      | ClusterGet
  deriving (Eq, Show, Typeable, Generic)

instance Binary MsgClusterStatus

-- | Test that we can set and query 'ClusterStatus' through a rule.
-- This test merely sends get/set messages and checks that the RG
-- changes accordingly.
testClusterStatus :: Transport -> IO ()
testClusterStatus transport = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid
  let sendSelf :: String -> Process ()
      sendSelf = usend self

  registerInterceptor $ \case
    str | "Cluster status is ONLINE" `isInfixOf` str ->
            sendSelf "OnlineGet"
        | "Set cluster status to ONLINE" `isInfixOf` str ->
            sendSelf "OnlineSet"
        | "Cluster status is QUIESCING" `isInfixOf` str ->
            sendSelf "QuiescingGet"
        | "Set cluster status to QUIESCING" `isInfixOf` str ->
            sendSelf "QuiescingSet"
        | "Cluster status is RECOVERING" `isInfixOf` str ->
            sendSelf "RecoveringGet"
        | "Set cluster status to RECOVERING" `isInfixOf` str ->
            sendSelf "RecoveringSet"
        | "Node succesfully joined the cluster" `isInfixOf` str ->
            sendSelf "NodeUp"
        | otherwise -> return ()

  withTrackingStation clusterStatusRules $ \_ -> do
    nodeUp ([nid], 1000000)
    -- wait for node to come up
    "NodeUp" :: String <- expect
    let sendCluster msg = promulgateEQ [nid] msg >>= flip withMonitor wait
    -- Check that we're ONLINE even though we haven't set it
    sendCluster ClusterGet
    "OnlineGet" :: String <- expect
    -- then just set and get a bunch and make sure things happen
    sendCluster (ClusterSet QUIESCING)
    "QuiescingSet" :: String <- expect
    sendCluster ClusterGet
    "QuiescingGet" :: String <- expect
    sendCluster (ClusterSet RECOVERING)
    "RecoveringSet" :: String <- expect
    sendCluster ClusterGet
    "RecoveringGet" :: String <- expect
    sendCluster (ClusterSet ONLINE)
    "OnlineSet" :: String <- expect
    sendCluster ClusterGet
    "OnlineGet" :: String <- expect
    return ()
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    clusterStatusRules :: [Definitions LoopState ()]
    clusterStatusRules = return $ defineSimple "cluster-status" $ \(HAEvent _ cmsg _) -> case cmsg of
        ClusterGet -> do
          cs <- getClusterStatus
          liftProcess . say $ "Cluster status is " ++ show cs
        ClusterSet cs -> do
          setClusterStatus cs
          liftProcess . say $ "Set cluster status to " ++ show cs

-- | Tests decision-log service by starting it and redirecting the logs to own
--  process, then starting a dummy service and checking that logs were
--  received.
testDecisionLog :: Transport -> IO ()
testDecisionLog transport = do
    withTmpDirectory $ tryWithTimeout transport testRemoteTable 15000000 $ do
      nid <- getSelfNode
      self <- getSelfPid

      withTrackingStation emptyRules $ \(TestArgs _ mm rc) -> do
        nodeUp ([nid], 1000000)
        -- Awaits the node local monitor to be up.
        _ <- getNodeMonitor mm

        subscribe rc (Proxy :: Proxy (HAEvent ServiceStartedMsg))
        serviceStart DLog.decisionLog (DLog.processOutput self)
        _ <- serviceStarted (serviceName DLog.decisionLog)
        serviceStart Dummy.dummy (Dummy.DummyConf $ Configured "Test 1")
        _ <- serviceStarted (serviceName Dummy.dummy)


        (_ :: Logs) <- expect
        return ()


testServiceStopped :: Transport -> IO ()
testServiceStopped transport = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      _ -> return ()

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    _ <- promulgateEQ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    "Starting service dummy" :: String <- expect
    say $ "dummy service started successfully."

    pid <- getServiceProcessPid mm (Node nid) Dummy.dummy
    _ <- monitor pid
    _ <- promulgateEQ [nid] . encodeP $ ServiceStopRequest (Node nid)
                                                           Dummy.dummy

    (_ :: ProcessMonitorNotification) <- expect
    say $ "dummy service stopped."


-- | Make sure that when a Service died, the node-local monitor detects it
--   and notify the RC. That service should restart.
testMonitorManagement :: Transport -> IO ()
testMonitorManagement transport = runDefaultTest transport $ do
  withTrackingStation emptyRules $ \(TestArgs _ mm rc) -> do
    nid <- getSelfNode
    nodeUp ([nid], 1000000)
    -- Awaits the node local monitor to be up.
    _ <- getNodeMonitor mm

    subscribe rc (Proxy :: Proxy (HAEvent ServiceStartedMsg))
    serviceStart Dummy.dummy (Dummy.DummyConf $ Configured "Test 1")
    dpid <- serviceStarted (serviceName Dummy.dummy)
    say "Service dummy has been started"

    kill dpid "Farewell"
    _ <- serviceStarted (serviceName Dummy.dummy)
    say "Service dummy has been re-started"

-- | Make sure that when a node-local monitor died, the RC is notified by the
--   Master monitor and restart it.
testMasterMonitorManagement :: Transport -> IO ()
testMasterMonitorManagement transport = runDefaultTest transport $ do
  withTrackingStation emptyRules $ \(TestArgs eq mm rc) -> do
    nodeUp ([processNodeId eq], 1000000)

    -- Awaits the node local monitor to be up.
    mpid <- getNodeMonitor mm

    subscribe rc (Proxy :: Proxy (HAEvent ServiceStartedMsg))
    say "Node-local monitor has been started"

    kill mpid "Farewell"
    _ <- serviceStarted monitorServiceName
    say "Node-local monitor has been restarted"

-- | This test verifies that if service start message is interleaved with
-- ServiceStart messages from the old node, that is possibe in case
-- of network failures.
testNodeUpRace :: Transport -> IO ()
testNodeUpRace transport = runTest 2 20 15000000 transport testRemoteTable $ \[node2] -> do
  nid <- getSelfNode
  self <- getSelfPid
--  void $ startEQTracker [nid]

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs eq mm _) -> do
    subscribe eq (Proxy :: Proxy TrimDone)

    void . liftIO $ forkProcess node2 $ do
      void $ startEQTracker [nid]
      selfNode <- getSelfNode
      _ <- promulgateEQ [nid] . encodeP $ ServiceStarted (Node selfNode)
                                                         Monitor.regularMonitor
                                                         Monitor.emptyMonitorConf
                                                         (ServiceProcess $ nullProcessId selfNode)
      nodeUp ([nid], 2000000)
      usend self (Node selfNode)
      usend self (nullProcessId selfNode)
      usend self ((), ())
    ((), ()) <- expect
    _ <- receiveTimeout 1000000 []

    nn <- expect
    pr <- expect
    rg <- G.getGraph mm
    case runningService nn Monitor.regularMonitor rg of
      Just (ServiceProcess n) -> do True <- return $ n /= pr
                                    return ()
      Nothing -> return ()
