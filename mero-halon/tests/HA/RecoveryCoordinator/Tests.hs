{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013-2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
import           Data.Defaultable
import           Data.Typeable
import           GHC.Generics
import           HA.Encode
import           HA.EventQueue
import           HA.EventQueue.Process
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.RC.Actions (defineSimpleTask, RC)
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Service.Events
import           HA.Replicator
import           HA.Resources
import           HA.SafeCopy
import           HA.Service
import qualified HA.Services.DecisionLog as DLog
import qualified HA.Services.Dummy as Dummy
import           Network.CEP (LogType, subscribe, Definitions)
import qualified Network.CEP.Log as Log
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
    sayTest "started"
    nodeUp [nid]

    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))

    promulgateEQ_ [nid] . encodeP $
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
    nodeUp [nid]
    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))

    promulgateEQ_ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    pid <- serviceStarted Dummy.dummy
    sayTest $ "Dummy service started successfully."

    promulgateEQ_ [nid] $
           ServiceFailed (Node nid)
                         (encodeP $ ServiceInfo Dummy.dummy (Dummy.DummyConf $ Configured "Test 1"))
                         (nullProcessId nid)

    pid2 <- getServiceProcessPid (Node nid) Dummy.dummy
    liftIO $ assertEqual "Same service keeps running" pid pid2
    sayTest $ "testServiceNotRestarting finished"

-- | Used in 'testEQTrimming'
data Step = Step

-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimming :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testEQTrimming transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  sayTest $ "tests node: " ++ show nid
  withTrackingStation pg [stepRule] $ \(TestArgs eq _ rc) -> do
    nodeUp [nid]
    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))
    subscribe eq (Proxy :: Proxy TrimDone)
    replicateM_ 10 $ promulgateEQ [nid] Step
    TrimDone{} <- expectPublished

    promulgateEQ_ [nid] $  encodeP $
      ServiceStartRequest Start (Node nid)
        Dummy.dummy (Dummy.DummyConf $ Configured "Test 1")
        []

    TrimDone{} <- expectPublished
    pid <- serviceStarted Dummy.dummy
    kill pid "test"
    replicateM_ 10 $ promulgateEQ [nid] Step

    TrimDone{} <- expectPublished
    sayTest $ "Everything got trimmed"
  where
    stepRule :: Definitions RC ()
    stepRule = defineSimpleTask "step" $ \Step -> return ()

-- | Used by 'testEQTrimUnknown'
data AbraCadabra = AbraCadabra deriving (Typeable, Generic)

-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimUnknown :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testEQTrimUnknown transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  say $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs eq _ _) -> do
    subscribe eq (Proxy :: Proxy TrimDone)
    nodeUp [nid]
    promulgateEQ_ [nid] AbraCadabra
    TrimDone{} <- expectPublished
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
        nodeUp [nid]
        -- Awaits the node local monitor to be up.
        subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))
        serviceStart DLog.decisionLog (DLog.processOutput self)
        _ <- serviceStarted DLog.decisionLog
        serviceStart Dummy.dummy (Dummy.DummyConf $ Configured "Test 1")
        _ <- serviceStarted Dummy.dummy
        (_ :: Log.Event (LogType RC)) <- expect
        return ()

testServiceStopped :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testServiceStopped transport pg = runDefaultTest transport $ do
  nid <- getSelfNode

  sayTest $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs _ _ rc) -> do
    nodeUp [nid]
    subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))
    promulgateEQ_ [nid] . encodeP $
      ServiceStartRequest Start (Node nid) Dummy.dummy
        (Dummy.DummyConf $ Configured "Test 1") []

    pid <- serviceStarted Dummy.dummy
    sayTest $ "dummy service started successfully."

    _ <- monitor pid
    promulgateEQ_ [nid] . encodeP $ ServiceStopRequest (Node nid) Dummy.dummy

    (_ :: ProcessMonitorNotification) <- expect
    sayTest $ "dummy service stopped."

deriveSafeCopy 0 'base ''AbraCadabra
deriveSafeCopy 0 'base ''Step
