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
  , testDecisionLog
  , testServiceStopped
  , tests
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types (nullProcessId)
import           Control.Monad (replicateM_)
import           Data.Binary
import           Data.Defaultable
import           Data.Typeable
import           GHC.Generics
import           HA.Encode
import           HA.EventQueue
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Actions.Core (defineSimpleTask, LoopState)
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Events.Service
import           HA.Replicator
import           HA.Resources
import           HA.Service
import qualified HA.Services.DecisionLog as DLog
import qualified HA.Services.Dummy as Dummy
import           Network.CEP (subscribe, Definitions, Logs(..))
import           Network.Transport (Transport)
import           Prelude hiding ((<$>), (<*>))
import           Test.Framework
import           Test.Tasty.HUnit (testCase, assertEqual)
import           TestRunner

tests :: (RGroup g, Typeable g) => Transport -> Proxy g -> [TestTree]
tests transport pg =
  [ testCase "testServiceRestarting" $ testServiceRestarting transport pg
  , testCase "testServiceNotRestarting" $ testServiceNotRestarting transport pg
  , testCase "testEQTrimming" $ testEQTrimming transport pg
  , testCase "testEQTrimUnknown" $ testEQTrimUnknown transport pg
  , testCase "testDecisionLog" $ testDecisionLog transport pg
  , testCase "testServiceStopped" $ testServiceStopped transport pg
  ]

-- | Test that the recovery co-ordinator can successfully restart a service
--   upon notification of failure.
--   This test does not verify the appropriate detection of service failure,
--   nor does it verify that the 'one service instance per node' constraint
--   is not violated.
testServiceRestarting :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testServiceRestarting transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  sayTest $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs _ _ rc) -> do
    nodeUp ([nid], 1000000)

    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))

    _ <- promulgateEQ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    pid <- serviceStarted Dummy.dummy
    sayTest $ "Dummy service started successfully. Faking service death."
    exit pid Fail
    sayTest $ "Waiting for service to restart."
    _ <- serviceStarted Dummy.dummy
    sayTest $ "testServiceRestarting finished"

-- | This test verifies that no service is killed when we send a `ServiceFailed`
--   With a wrong `ProcessId`
--
-- TODO: This test seems like it might not be testing what it should
-- be that well: if 'ServiceFailed' doesn't get processed before we
-- ask for a service 'ProcessId', how could we know that we have
-- succeeded at all?
testServiceNotRestarting :: (Typeable g, RGroup g)
                         => Transport -> Proxy g -> IO ()
testServiceNotRestarting transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  sayTest $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs _ _ rc) -> do
    nodeUp ([nid], 1000000)
    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))

    _ <- promulgateEQ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    pid <- serviceStarted Dummy.dummy
    sayTest $ "Dummy service started successfully."

    _ <- promulgateEQ [nid] $
           ServiceFailed (Node nid)
                         (encodeP $ ServiceInfo Dummy.dummy (Dummy.DummyConf $ Configured "Test 1"))
                         (nullProcessId nid)

    pid2 <- getServiceProcessPid (Node nid) Dummy.dummy
    liftIO $ assertEqual "Same service keeps running" pid pid2
    sayTest $ "testServiceNotRestarting finished"

-- | Used in 'testEQTrimming'
newtype Step = Step () deriving (Binary)

-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimming :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testEQTrimming transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  sayTest $ "tests node: " ++ show nid
  withTrackingStation pg [stepRule] $ \(TestArgs eq _ rc) -> do
    nodeUp ([nid], 1000000)
    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))
    subscribe eq (Proxy :: Proxy TrimDone)
    replicateM_ 10 $ promulgateEQ [nid] $ Step ()
    TrimDone{} <- expectPublished Proxy

    _ <- promulgateEQ [nid] $  encodeP $
      ServiceStartRequest Start (Node nid)
        Dummy.dummy (Dummy.DummyConf $ Configured "Test 1")
        []

    TrimDone{} <- expectPublished Proxy
    pid <- serviceStarted Dummy.dummy
    kill pid "test"
    replicateM_ 10 $ promulgateEQ [nid] $ Step ()

    TrimDone{} <- expectPublished Proxy
    sayTest $ "Everything got trimmed"
  where
    stepRule :: Definitions LoopState ()
    stepRule = defineSimpleTask "step" $ \Step{} -> return ()

-- | Used by 'testEQTrimUnknown'
data AbraCadabra = AbraCadabra deriving (Typeable, Generic)
instance Binary AbraCadabra

-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimUnknown :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testEQTrimUnknown transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  say $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs eq _ _) -> do
    subscribe eq (Proxy :: Proxy TrimDone)
    nodeUp ([nid], 1000000)
    _ <- promulgateEQ [nid] AbraCadabra
    TrimDone{} <- expectPublished Proxy
    return ()

-- | Tests decision-log service by starting it and redirecting the logs to own
--  process, then starting a dummy service and checking that logs were
--  received.
testDecisionLog :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDecisionLog transport pg = do
    withTmpDirectory $ tryWithTimeout transport testRemoteTable 15000000 $ do
      nid <- getSelfNode
      self <- getSelfPid

      withTrackingStation pg emptyRules $ \(TestArgs _ _ rc) -> do
        nodeUp ([nid], 1000000)
        -- Awaits the node local monitor to be up.
        subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))
        serviceStart DLog.decisionLog (DLog.processOutput self)
        _ <- serviceStarted DLog.decisionLog
        serviceStart Dummy.dummy (Dummy.DummyConf $ Configured "Test 1")
        _ <- serviceStarted Dummy.dummy
        (_ :: Logs) <- expect
        return ()

testServiceStopped :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testServiceStopped transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  sayTest $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs _ _ rc) -> do
    nodeUp ([nid], 1000000)
    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))
    _ <- promulgateEQ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    pid <- serviceStarted Dummy.dummy
    sayTest $ "dummy service started successfully."

    _ <- monitor pid
    _ <- promulgateEQ [nid] . encodeP $ ServiceStopRequest (Node nid)
                                                           Dummy.dummy

    (_ :: ProcessMonitorNotification) <- expect
    sayTest $ "dummy service stopped."
