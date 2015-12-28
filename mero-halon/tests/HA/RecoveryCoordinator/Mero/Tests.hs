-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}

module HA.RecoveryCoordinator.Mero.Tests
  ( testClusterStatus
  , testDriveAddition
  , testDriveManagerUpdate
  , testHostAddition
  , testServiceRestarting
  , testServiceNotRestarting
  , testEQTrimming
  , testEQTrimUnknown
  , testDecisionLog
  , testServiceStopped
  , testMonitorManagement
  , testMasterMonitorManagement
  , testNodeUpRace
#ifdef USE_MERO
  , testRCsyncToConfd
#endif
  , emptyRules__static
  ) where

import Prelude hiding ((<$>), (<*>))
import Test.Framework

import HA.Resources
import HA.Resources.Castor
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.EventQueue
import HA.EventQueue.Types (HAEvent(..))
import HA.EventQueue.Producer (promulgateEQ)
import HA.Multimap
import HA.Multimap.Implementation
import HA.Replicator
import HA.EQTracker
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor.Initial as CI
import HA.Service
  ( Configuration
  , Service(..)
  , ServiceName(..)
  , ServiceFailed(..)
  , ServiceProcess(..)
  , ServiceStart(..)
  , ServiceStartRequest(..)
  , ServiceStopRequest(..)
  , ServiceStarted(..)
  , ServiceStartedMsg
  , decodeP
  , encodeP
  , runningService
  )
import           HA.NodeUp (nodeUp)
import qualified HA.Services.Dummy as Dummy
import qualified HA.Services.Monitor as Monitor
import qualified HA.Services.DecisionLog as DLog
import HA.Services.Monitor
import RemoteTables ( remoteTable )

import qualified SSPL.Bindings as SSPL

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( mkStatic )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Network.Transport (Transport(..))

import Control.Monad (void, join)
import Data.Defaultable
import Data.List (isInfixOf)
import Network.CEP (defineSimple, liftProcess, subscribe, Definitions , Published(..), Logs(..))
import Test.Tasty.HUnit (assertBool)
import TestRunner
import Data.Binary
import Data.Typeable
import qualified Data.Text as T
import GHC.Generics
import Helper.SSPL
import Helper.Environment (systemHostname)

#ifdef USE_MERO
import HA.Castor.Tests (initialDataAddr)
import HA.RecoveryCoordinator.Actions.Mero (syncToConfd)
import Mero.Notification (initialize_pre_m0_init)
import qualified Helper.InitialData
#endif

import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)

#ifdef USE_MERO
-- | label used to test spiel sync through a rule
data SpielSync = SpielSync
  deriving (Eq, Show, Typeable, Generic)

instance Binary SpielSync
#endif

#ifdef USE_MERO
testSyncRules :: [Definitions LoopState ()]
testSyncRules = return $ defineSimple "spiel-sync" $ \(HAEvent _ SpielSync _) -> do
  result <- syncToConfd
  case result of
    Left e -> liftProcess $ say $ "Exceptions during sync: "++ show e
    Right{} -> liftProcess $ say "Finished sync to confd"
#endif

runRC :: (ProcessId, IgnitionArguments)
      -> MC_RG TestReplicatedState
      -> Process ((StoreChan, ProcessId)) -- ^ MM, RC
runRC (eq, args) rGroup = runRCEx (eq, args) emptyRules rGroup

getServiceProcessPid :: Configuration a
                     => StoreChan
                     -> Node
                     -> Service a
                     -> Process ProcessId
getServiceProcessPid mm n sc = do
    rg <- G.getGraph mm
    case runningService n sc rg of
      Just (ServiceProcess pid) -> return pid
      _ -> do
        _ <- receiveTimeout 500000 []
        getServiceProcessPid mm n sc

serviceProcessStillAlive :: Configuration a
                         => StoreChan
                         -> Node
                         -> Service a
                         -> Process Bool
serviceProcessStillAlive mm n sc = loop (1 :: Int)
  where
    loop i | i > 3     = return True
           | otherwise = do
                 rg <- G.getGraph mm
                 case runningService n sc rg of
                   Just _ -> do
                     _ <- receiveTimeout 250000 []
                     loop (i + 1)
                   _ -> return False

-- | Test that the recovery co-ordinator can successfully restart a service
--   upon notification of failure.
--   This test does not verify the appropriate detection of service failure,
--   nor does it verify that the 'one service instance per node' constraint
--   is not violated.
testServiceRestarting :: Transport -> IO ()
testServiceRestarting transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid
      registerInterceptor $ \string -> case string of
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
  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable

-- | This test verifies that no service is killed when we send a `ServiceFailed`
--   With a wrong `ProcessId`
testServiceNotRestarting :: Transport -> IO ()
testServiceNotRestarting transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      registerInterceptor $ \string -> case string of
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
  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable

-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimming :: Transport -> IO ()
testEQTrimming transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
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
  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable

data AbraCadabra = AbraCadabra deriving (Typeable, Generic)
instance Binary AbraCadabra

-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimUnknown :: Transport -> IO ()
testEQTrimUnknown transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode

      say $ "tests node: " ++ show nid
      withTrackingStation emptyRules $ \(TestArgs eq _ _) -> do
        subscribe eq (Proxy :: Proxy TrimUnknown)
        nodeUp ([nid], 1000000)
        _ <- promulgateEQ [nid] AbraCadabra
        Published (TrimUnknown _) _ <- expect
        say $ "Everything got trimmed"
  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable

-- | Test that the recovery co-ordinator successfully adds a host to the
--   resource graph.
testHostAddition :: Transport -> IO ()
testHostAddition transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      registerInterceptor $ \string -> case string of
          str@"Starting service dummy"   -> usend self str
          str' | "Registered host" `isInfixOf` str' ->
            usend self ("Host" :: String)
          _ -> return ()

      say $ "tests node: " ++ show nid
      withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
        nodeUp ([nid], 1000000)
        say "Send host update message to the RC"
        promulgateEQ [nid] (nid, mockEvent) >>= (flip withMonitor) wait
        "Host" :: String <- expect

        say "Load graph"
        graph <- G.getGraph mm
        let host = Host "mockhost"
            node = Node nid
        liftIO $ do
          assertBool (show host ++ " is not in graph") $
            G.memberResource host graph
          assertBool (show host ++ " is not connected to " ++ show node) $
            G.memberEdge (G.Edge host Runs node) graph

  where
    wait = void (expect :: Process ProcessMonitorNotification)
    rt = TestRunner.__remoteTableDecl $
         remoteTable
    mockEvent = (emptyHostUpdate "mockhost")
      { SSPL.sensorResponseMessageSensor_response_typeHost_updateUname = Just "mockhost"
      }

-- | Test that the recovery co-ordinator successfully adds a drive to the RG,
--   and updates its status accordingly.
testDriveAddition :: Transport -> IO ()
testDriveAddition transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      registerInterceptor $ \string -> case string of
          str@"Starting service dummy"   -> usend self str
          str' | "Updating status for device StorageDevice" `isInfixOf` str' ->
            usend self ("Drive" :: String)
          _ -> return ()

      say $ "tests node: " ++ show nid
      withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
        nodeUp ([nid], 1000000)
        -- Send host update message to the RC
        promulgateEQ [nid] (nid, mockEvent "online") >>= (flip withMonitor) wait
        "Drive" :: String <- expect

        graph <- G.getGraph mm
        let enc = Enclosure "enc1"
            drive = head $ (G.connectedTo enc Has graph :: [StorageDevice])
            status = StorageDeviceStatus "online"
        liftIO $ do
          assertBool "Enclosure exists in a graph"  $ G.memberResource enc graph
          assertBool "Drive exists in a graph"      $ G.memberResource drive graph
          assertBool "Status exists in a graph"     $ G.memberResource status graph
          assertBool "Enclosure connected to drive" $ G.memberEdge (G.Edge enc Has drive) graph
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    rt = TestRunner.__remoteTableDecl $
         remoteTable
    mockEvent = mkResponseDriveManager "enc1" "serial1" 1

-- | Used by 'testDriveManagerUpdate'
data RunDriveManagerFailure = RunDriveManagerFailure
  deriving (Eq, Show, Typeable, Generic)

instance Binary RunDriveManagerFailure

-- | Update receiving a drive failure from SSPL, we're required to
-- update a file for DCS drive manager so that it can reflect on the
-- changes in the file system. This test is unsophisticated in that it
-- only tests that the change to the file is made when event is
-- received and not that the drive manager does something sensible
-- with it.
--
-- * Write out a mock @drive_manager.json@ to have something to update
-- * Insert a drive into RG along with its serial number
-- * Trigger a test rule that calls 'driveManagerUpdateWithFailure'
-- * Check that the failure is now present in the relevant file
--
-- For the sake of testing this, we cheat a bit by triggering it with
-- our own rule. The alternative would be to simulate all kinds of
-- responses from SSPL which aren't central to the feature and are
-- tested separately elsewhere.
testDriveManagerUpdate :: Transport -> IO ()
testDriveManagerUpdate transport = runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
  nid <- getSelfNode
  self <- getSelfPid
  registerInterceptor $ \case
    str | "drive_manager.json updated successfully" `isInfixOf` str ->
            usend self ("DMUpdated" :: String)
        | "Node succesfully joined the cluster" `isInfixOf` str ->
            usend self  ("NodeUp" :: String)
        | "Loaded initial data" `isInfixOf` str ->
            usend self  ("InitialData" :: String)
        | "at 1 marked as active" `isInfixOf` str ->
            usend self  ("DriveActive" :: String)
        | otherwise -> return ()
  liftIO $ createDirectoryIfMissing True "/tmp/drivemanager"
  say $ "Writing drive_manager.json with:\n" ++ mockFile
  liftIO $ writeFile "/tmp/drivemanager/drive_manager.json" mockFile
  withTrackingStation testRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    "NodeUp" :: String <- expect
    promulgateEQ [nid] initialData >>= flip withMonitor wait
    "InitialData" :: String <- expect

    say "Sending online message"
    promulgateEQ [nid] (nid, respDM "online") >>= flip withMonitor wait
    "DriveActive" :: String <- expect

    say "Checking drive status sanity"
    graph <- G.getGraph mm
    let [drive] = [ d | d <- G.connectedTo (Enclosure enc) Has graph :: [StorageDevice]
                      , DISerialNumber sn <- G.connectedTo d Has graph
                      , sn == interestingSN
                  ]
    assert $ G.memberResource drive graph
    assert $ G.memberResource (StorageDeviceStatus "online") graph

    say "Sending RunDriveManagerFailure"
    promulgateEQ [nid] RunDriveManagerFailure >>= flip withMonitor wait
    "DMUpdated" :: String <- expect
    content <- liftIO $ readFile "/tmp/drivemanager/drive_manager.json"
    say $ "drive_manager.json content: \n" ++ content
    assert $ "Failed" `isInfixOf` content
    liftIO $ removeDirectoryRecursive "/tmp/drivemanager"
  where
    testRules :: [Definitions LoopState ()]
    testRules = return $ defineSimple "dmwf-trigger" $ \(HAEvent _ RunDriveManagerFailure _) -> do
      liftProcess $ say "test rule triggered"
      -- Find what should be the only SD in the enclosure and trigger
      -- repair on it
      graph <- getLocalGraph
      let [sd]  = G.connectedTo (Enclosure enc) Has graph
      updateDriveManagerWithFailure sd

    wait = void (expect :: Process ProcessMonitorNotification)
    enc :: String
    enc = "enclosure1"
    interestingSN :: String
    interestingSN = "Z8407MGP"
    respDM = mkResponseDriveManager (T.pack enc) (T.pack interestingSN) 1
    initialData = CI.InitialData {
      CI.id_racks = [
        CI.Rack {
          CI.rack_idx = 1
        , CI.rack_enclosures = [
            CI.Enclosure {
              CI.enc_idx = 1
            , CI.enc_id = enc
            , CI.enc_bmc = [CI.BMC "192.0.2.1" "admin" "admin"]
            , CI.enc_hosts = [
                CI.Host {
                  CI.h_fqdn = systemHostname
                , CI.h_memsize = 4096
                , CI.h_cpucount = 8
                , CI.h_interfaces = [
                    CI.Interface {
                      CI.if_macAddress = "10-00-00-00-00"
                    , CI.if_network = CI.Data
                    , CI.if_ipAddrs = ["192.0.2.2"]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
#ifdef USE_MERO
      , CI.id_m0_servers = fmap (\s -> s{CI.m0h_devices = []})
                                (CI.id_m0_servers Helper.InitialData.initialData)
      , CI.id_m0_globals = (CI.id_m0_globals Helper.InitialData.initialData)
                            { CI.m0_failure_set_gen  = CI.Dynamic }
#endif
      }
    mockFile = unlines
      [ "{"
      , "\"drive_manager_version\": 0,"
      , "\"drives\": ["
      , "  {"
      , "    \"reason\": \"None\","
      , "    \"serial_number\": \"" ++ interestingSN ++ "\","
      , "    \"status\": \"OK\""
      , "  },"
      , "  {"
      , "    \"reason\": \"None\","
      , "    \"serial_number\": \"SOMEUNKNOWNDRIVE\","
      , "    \"status\": \"OK\""
      , "  }"
      , "],"
      , "\"format_version\": 0,"
      , "\"last_update_time\": \"1448638074.41\""
      , "}"
      ]

-- | Message used by 'testClusterStatus'.
data MsgClusterStatus = ClusterSet ClusterStatus
                      | ClusterGet
  deriving (Eq, Show, Typeable, Generic)

instance Binary MsgClusterStatus

clusterStatusRules :: [Definitions LoopState ()]
clusterStatusRules = return $ defineSimple "cluster-status" $ \(HAEvent _ cmsg _) -> case cmsg of
    ClusterGet -> do
      cs <- getClusterStatus
      liftProcess . say $ "Cluster status is " ++ show cs
    ClusterSet cs -> do
      setClusterStatus cs
      liftProcess . say $ "Set cluster status to " ++ show cs

-- | Test that we can set and query 'ClusterStatus' through a rule.
testClusterStatus :: Transport -> IO ()
testClusterStatus transport = do
  runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
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

testDecisionLog :: Transport -> IO ()
testDecisionLog transport = do
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
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
  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable

testServiceStopped :: Transport -> IO ()
testServiceStopped transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      registerInterceptor $ \string -> case string of
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
  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable

serviceStarted :: ServiceName -> Process ProcessId
serviceStarted svname = do
    mp@(Published (HAEvent _ msg _) _)          <- expect
    ServiceStarted _ svc _ (ServiceProcess pid) <- decodeP msg
    if serviceName svc == svname
        then return pid
        else do
          self <- getSelfPid
          usend self mp
          serviceStarted svname

serviceStart :: Configuration a => Service a -> a -> Process ()
serviceStart svc conf = do
    nid <- getSelfNode
    let node = Node nid
    _   <- promulgateEQ [nid] $ encodeP $ ServiceStartRequest Start node svc conf []
    return ()

getNodeMonitor :: StoreChan -> Process ProcessId
getNodeMonitor mm = do
    nid <- getSelfNode
    rg  <- G.getGraph mm
    let n = Node nid
    case runningService n regularMonitor rg of
      Just (ServiceProcess pid) -> return pid
      _  -> do
        _ <- receiveTimeout 100 []
        getNodeMonitor mm

-- | Make sure that when a Service died, the node-local monitor detects it
--   and notify the RC. That service should restart.
testMonitorManagement :: Transport -> IO ()
testMonitorManagement transport = do
    runTest 1 20 15000000 transport testRemoteTable $ \_ ->
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
testMasterMonitorManagement transport = do
    runTest 1 20 15000000 transport testRemoteTable $ \_ ->
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
testNodeUpRace transport = do
    runTest 2 20 15000000 transport rt $ \[node2] -> do
      nid <- getSelfNode
      self <- getSelfPid
      void $ startEQTracker [nid]

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do

        eq <- startEventQueue (viewRState $(mkStatic 'eqView) rGroup)
        subscribe eq (Proxy :: Proxy TrimDone)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        _ <- liftIO $ forkProcess node2 $ do
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

  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable

#ifdef USE_MERO
-- | Sends a message to the RC with Confd addition message and tests
-- that it gets added to the resource graph.
testRCsyncToConfd :: String -- ^ IP we're listening on, used in this
                            -- test to assume confd server is on the
                            -- same host
                  -> Transport -> IO ()
testRCsyncToConfd host transport = do
 withTestEnv $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
    str' | "Finished sync to confd" `isInfixOf` str' -> usend self ("SyncOK" :: String)
         | "Loaded initial data" `isInfixOf` str' -> usend self ("InitialLoad" :: String)
         | otherwise -> return ()

  withTrackingStation testSyncRules $ \_ -> do

    promulgateEQ [nid] (initialDataAddr host host 2) >>= flip withMonitor wait
    "InitialLoad" :: String <- expect

    promulgateEQ [nid] SpielSync >>= flip withMonitor wait
    "SyncOK" :: String <- expect
    return ()
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    withTestEnv f = withTmpDirectory $ tryWithTimeoutIO transport testRemoteTable (3*60*1000000)
                  $ \lnid -> do
      initialize_pre_m0_init lnid
      runProcess lnid f

#endif

testRemoteTable :: RemoteTable
testRemoteTable = TestRunner.__remoteTableDecl $
                  remoteTable
