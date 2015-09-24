-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module HA.RecoveryCoordinator.Mero.Tests
  ( testDriveAddition
  , testHostAddition
  , testServiceRestarting
  , testServiceNotRestarting
  , testEQTrimming
--  , testDecisionLog
  , testServiceStopped
  , testMonitorManagement
  , testMasterMonitorManagement
  , testNodeUpRace
  ) where

import Prelude hiding ((<$>), (<*>))
import Test.Framework

import HA.Resources
import HA.Resources.Castor
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.EventQueue
import HA.EventQueue.Definitions
import HA.EventQueue.Types (HAEvent(..))
import HA.EventQueue.Producer (promulgateEQ)
import HA.Multimap.Implementation
import HA.Multimap.Process
import HA.Replicator
import HA.EQTracker ( eqTrackerProcess )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import qualified HA.ResourceGraph as G
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
--   , Owns(..)
  , decodeP
  , encodeP
  , runningService
  )
import           HA.NodeUp (nodeUp)
import qualified HA.Services.Dummy as Dummy
import qualified HA.Services.Monitor as Monitor
-- import qualified HA.Services.DecisionLog as DLog
import HA.Services.Monitor
import RemoteTables ( remoteTable )

import qualified SSPL.Bindings as SSPL

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( remotableDecl, mkStatic )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Internal.Types (nullProcessId)
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Network.Transport (Transport(..))
import Network.Transport.InMemory (createTransport)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ( first, second )
import qualified Control.Exception as E
import Control.Monad (forM_, void, join)

-- import qualified Data.Attoparsec.ByteString.Char8 as Atto
-- import qualified Data.ByteString as B
-- import qualified Data.ByteString.Char8 as B8
import Data.Defaultable
import Data.List (isInfixOf)
import Data.Proxy (Proxy(..))
import Network.CEP (Published(..), subscribe)
import System.IO
import System.Random
import System.Timeout
import System.Environment
import Test.Tasty.HUnit (assertBool)


type TestReplicatedState = (EventQueue, Multimap)

remotableDecl [ [d|
  eqView :: RStateView TestReplicatedState EventQueue
  eqView = RStateView fst first

  multimapView :: RStateView TestReplicatedState Multimap
  multimapView = RStateView snd second

  testDict :: SerializableDict TestReplicatedState
  testDict = SerializableDict
  |]]

runRC :: (ProcessId, IgnitionArguments)
      -> MC_RG TestReplicatedState
      -> Process ((ProcessId, ProcessId)) -- ^ MM, RC
runRC (eq, args) rGroup = do
  rec (mm, rc) <- (,)
                  <$> (spawnLocal $ do
                        () <- expect
                        link rc
                        multimap (viewRState $(mkStatic 'multimapView) rGroup))
                  <*> (spawnLocal $ do
                        () <- expect
                        recoveryCoordinator args eq mm)
  usend eq rc
  forM_ [mm, rc] $ \them -> usend them ()
--  liftIO $ takeMVar var
  return (mm, rc)

getServiceProcessPid :: Configuration a
                     => ProcessId
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
                         => ProcessId
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
      _ <- spawnLocal $ eqTrackerProcess [nid]
      registerInterceptor $ \string -> case string of
          str@"Starting service dummy"   -> usend self str
          _ -> return ()

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest Start (Node nid) Dummy.dummy
            (Dummy.DummyConf $ Configured "Test 1")

        "Starting service dummy" :: String <- expect
        say $ "dummy service started successfully."

        pid <- getServiceProcessPid mm (Node nid) Dummy.dummy
        _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy
                                                          pid
        "Starting service dummy" :: String <- expect
        say $ "dummy service restarted successfully."
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable

-- | This test verifies that no service is killed when we send a `ServiceFailed`
--   With a wrong `ProcessId`
testServiceNotRestarting :: Transport -> IO ()
testServiceNotRestarting transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid
      _ <- spawnLocal $ eqTrackerProcess [nid]

      registerInterceptor $ \string -> case string of
          str@"Starting service dummy"   -> usend self str
          _ -> return ()

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest Start (Node nid) Dummy.dummy
            (Dummy.DummyConf $ Configured "Test 1")

        "Starting service dummy" :: String <- expect
        say $ "dummy service started successfully."

        -- Assert the service has been started
        _ <- getServiceProcessPid mm (Node nid) Dummy.dummy
        _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy self

        True <- serviceProcessStillAlive mm (Node nid) Dummy.dummy
        say $ "dummy service hasn't been killed."
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable

-- | This test verifies that every `HAEvent` sent to the RC is trimmed by the EQ
testEQTrimming :: Transport -> IO ()
testEQTrimming transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      _ <- spawnLocal $ eqTrackerProcess [nid]

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        subscribe eq (Proxy :: Proxy TrimDone)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        Published (TrimDone _) _ <- expect
        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest Start (Node nid) Dummy.dummy
            (Dummy.DummyConf $ Configured "Test 1")

        Published (TrimDone _) _ <- expect

        pid <- getServiceProcessPid mm (Node nid) Dummy.dummy
        _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy
                                                          pid

        Published (TrimDone _) _ <- expect
        say $ "Everything got trimmed"
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable

emptySensorMessage :: SSPL.SensorResponseMessageSensor_response_type
emptySensorMessage = SSPL.SensorResponseMessageSensor_response_type
  { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpi = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeIf_data = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeHost_update = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanager = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeService_watchdog = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeLocal_mount_data = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeCpu_data = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeRaid_data = Nothing
  }

-- | Test that the recovery co-ordinator successfully adds a host to the
--   resource graph.
testHostAddition :: Transport -> IO ()
testHostAddition transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid
      _ <- spawnLocal $ eqTrackerProcess [nid]

      registerInterceptor $ \string -> case string of
          str@"Starting service dummy"   -> usend self str
          str' | "Registered host" `isInfixOf` str' ->
            usend self ("Host" :: String)
          _ -> return ()

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm, _) <- runRC (eq, IgnitionArguments [nid]) rGroup

        -- Send host update message to the RC
        promulgateEQ [nid] (nid, mockEvent) >>= (flip withMonitor) wait
        "Host" :: String <- expect

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
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
    mockEvent = emptySensorMessage { SSPL.sensorResponseMessageSensor_response_typeHost_update =
      Just $ SSPL.SensorResponseMessageSensor_response_typeHost_update
        { SSPL.sensorResponseMessageSensor_response_typeHost_updateRunningProcessCount = Nothing
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateUname               = Just "mockhost"
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateHostId              = "mockhost"
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateLocaltime           = ""
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateUpTime              = Nothing
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateFreeMem             = Nothing
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateLoggedInUsers       = Nothing
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateTotalMem            = Nothing
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateProcessCount        = Nothing
        , SSPL.sensorResponseMessageSensor_response_typeHost_updateBootTime            = Nothing
        }
      }

-- | Test that the recovery co-ordinator successfully adds a drive to the RG,
--   and updates its status accordingly.
testDriveAddition :: Transport -> IO ()
testDriveAddition transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid
      _ <- spawnLocal $ eqTrackerProcess [nid]

      registerInterceptor $ \string -> case string of
          str@"Starting service dummy"   -> usend self str
          str' | "Registered drive" `isInfixOf` str' ->
            usend self ("Drive" :: String)
          _ -> return ()

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm, _) <- runRC (eq, IgnitionArguments [nid]) rGroup

        -- Send host update message to the RC
        promulgateEQ [nid] (nid, mockEvent "online") >>= (flip withMonitor) wait
        "Drive" :: String <- expect

        graph <- G.getGraph mm
        let enc = Enclosure "enc1"
            drive = head $ (G.connectedTo enc Has graph :: [StorageDevice])
            status = StorageDeviceStatus "online"
        assert $ G.memberResource enc graph
        assert $ G.memberResource drive graph
        assert $ G.memberResource status graph
        assert $ G.memberEdge (G.Edge enc Has drive) graph
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
    mockEvent status = emptySensorMessage { SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanager =
      Just $ SSPL.SensorResponseMessageSensor_response_typeDisk_status_drivemanager
        { SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN = "enc1"
        , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum = 1
        , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus = status
        }
    }

-- data DLogLine =
--     DLogLine
--     { dlogRuleId  :: !B.ByteString
--     , dlogPidStr  :: !String
--     , dlogCounter :: !Int
--     , dlogHops    :: ![String]
--     , dlogEntries :: ![(B.ByteString, String)]
--     } deriving Show

-- parsePID :: Atto.Parser B.ByteString
-- parsePID = Atto.takeWhile (\c -> c /= ',' && c /= ']')

-- parsePIDStr :: Atto.Parser String
-- parsePIDStr = fmap B8.unpack parsePID

-- parseEntry :: Atto.Parser (B.ByteString, String)
-- parseEntry = do
--     _   <- Atto.string "context="
--     ctx <- Atto.takeWhile (/= ';')
--     _   <- Atto.string ";log=\""
--     v   <- Atto.takeWhile (/= '"')
--     _   <- Atto.char '"'
--     return (ctx, B8.unpack v)

-- parseEntries :: Atto.Parser [(B.ByteString, String)]
-- parseEntries = parseEntry `Atto.sepBy1'` Atto.endOfLine

-- parseDLogLine :: Atto.Parser DLogLine
-- parseDLogLine = do
--     _      <- Atto.string "rule-id="
--     ruleid <- Atto.takeWhile (/= ';')
--     _      <- Atto.string ";inputs=eventId=EventId {eventNodeId = "
--     pid    <- parsePIDStr
--     _      <- Atto.string ", eventCounter = "
--     cnt    <- Atto.decimal
--     _      <- Atto.string "};eventHops=["
--     hs     <- parsePIDStr `Atto.sepBy1'` Atto.char ','
--     _      <- Atto.string "];;entries="
--     es     <- parseEntries
--     return DLogLine
--            { dlogRuleId   = ruleid
--            , dlogPidStr   = pid
--            , dlogCounter  = cnt
--            , dlogHops     = hs
--            , dlogEntries  = es
--            }

-- parseDLogLines :: Atto.Parser [DLogLine]
-- parseDLogLines = parseDLogLine `Atto.sepBy1'` Atto.endOfLine

-- readFileContents :: FilePath -> Process B.ByteString
-- readFileContents path = liftIO $ do
--     h <- openFile path ReadMode
--     B.hGetContents h

-- logExpectations :: ProcessId -> [DLogLine] -> Process ()
-- logExpectations eq xs@[x,y] = do
--     if dlogRuleId x == "service-started" &&
--        dlogCounter x == 1 &&
--        dlogEntries x == [("started", "Service decision-log started")] &&
--        dlogHops x    == [show eq] &&
--        dlogRuleId y == "service-started" &&
--        dlogCounter y == 1 &&
--        dlogEntries y == [("started", "Service dummy started")] &&
--        dlogHops y == [show eq]
--        then return ()
--        else error $ "Wrong expectation: " ++ show xs
-- logExpectations _ xs =
--     error $ "Expected 2 lines, got " ++ show (length xs) ++ " instead"

-- confirmDead :: ProcessId -> Process ()
-- confirmDead pid =
--     receiveWait [ matchIf (\(ProcessMonitorNotification _ p _) -> p == pid)
--                          (\_ -> return ()) ]

-- testDecisionLog :: Transport -> IO ()
-- testDecisionLog transport = do
--     withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
--         nid <- getSelfNode
--         self <- getSelfPid

--         registerInterceptor $ \string -> case string of
--             str@"entries submitted" -> send self str
--             _ -> return ()

--         say $ "tests node: " ++ show nid
--         cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
--                              [nid] ((Nothing,[]), fromList [])
--         pRGroup <- unClosure cRGroup
--         rGroup <- pRGroup
--         eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
--         (mm, rc) <- runRC (eq, IgnitionArguments [nid]) rGroup

--         nodeUp ([nid], 2000000)
--         _ <- promulgateEQ [nid] . encodeP $
--           ServiceStartRequest (Node nid) DLog.decisionLog
--             (DLog.DecisionLogConf "./dlog.log")

--         ("entries submitted" :: String) <- expect

--         _ <- promulgateEQ [nid] . encodeP $
--           ServiceStartRequest (Node nid) Dummy.dummy
--             (Dummy.DummyConf $ Configured "Test 1")

--         ("entries submitted" :: String) <- expect

--         rg <- G.getGraph mm
--         let sp :: ServiceProcess DLog.DecisionLogConf
--             sp = case G.connectedFrom Owns DLog.decisionLogServiceName rg of
--                    [sp'] -> sp'
--                    _     -> error "Can't retrieve DLog PID"
--             ServiceProcess dlogpid = sp

--         _ <- monitor rc
--         _ <- monitor dlogpid
--         kill rc "I killed you RC"
--         kill dlogpid "We want to access your log file"

--         confirmDead rc
--         confirmDead dlogpid
--         bs <- readFileContents "./dlog.log"
--         let res = Atto.parseOnly parseDLogLines bs
--         case res of
--           Left e   -> error $ "dlog parsing error: " ++ e
--           Right xs -> logExpectations eq xs
--   where
--     rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
--          remoteTable

testServiceStopped :: Transport -> IO ()
testServiceStopped transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid
      _ <- spawnLocal $ eqTrackerProcess [nid]

      registerInterceptor $ \string -> case string of
          str@"Starting service dummy"   -> usend self str
          _ -> return ()

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest Start (Node nid) Dummy.dummy
            (Dummy.DummyConf $ Configured "Test 1")

        "Starting service dummy" :: String <- expect
        say $ "dummy service started successfully."

        pid <- getServiceProcessPid mm (Node nid) Dummy.dummy
        _ <- monitor pid
        _ <- promulgateEQ [nid] . encodeP $ ServiceStopRequest (Node nid)
                                                               Dummy.dummy

        (_ :: ProcessMonitorNotification) <- expect
        say $ "dummy service stopped."
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
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

launchRC :: ((ProcessId, ProcessId) -> Process a) -> Process a
launchRC action = do
    nid <- getSelfNode
    _ <- spawnLocal $ eqTrackerProcess [nid]

    say $ "tests node: " ++ show nid
    bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                           [nid] ((Nothing,[]), fromList [])
                join $ unClosure cRGroup
            )
            (flip killReplica nid) $ \rGroup -> do
      eq      <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
      runRC (eq, IgnitionArguments [nid]) rGroup >>= action

serviceStart :: Configuration a => Service a -> a -> Process ()
serviceStart svc conf = do
    nid <- getSelfNode
    let node = Node nid
    _   <- promulgateEQ [nid] $ encodeP $ ServiceStartRequest Start node svc conf
    return ()

getNodeMonitor :: ProcessId -> Process ProcessId
getNodeMonitor mm = do
    nid <- getSelfNode
    rg  <- G.getGraph mm
    let n = Node nid
    case runningService n regularMonitor rg of
      Just (ServiceProcess pid) -> return pid
      _  -> do
        _ <- receiveTimeout 100000 []
        getNodeMonitor mm

-- | Make sure that when a Service died, the node-local monitor detects it
--   and notify the RC. That service should restart.
testMonitorManagement :: Transport -> IO ()
testMonitorManagement transport = do
    runTest 1 20 15000000 transport testRemoteTable $ \_ ->
      launchRC $ \(mm, rc) -> do
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
      launchRC $ \(mm, rc) -> do

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
      _ <- spawnLocal $ eqTrackerProcess [nid]

      say $ "tests node: " ++ show nid
      bracket (do cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
                  join $ unClosure cRGroup
              )
              (flip killReplica nid) $ \rGroup -> do

        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        subscribe eq (Proxy :: Proxy TrimDone)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        _ <- liftIO $ forkProcess node2 $ do
            _ <- spawnLocal $ eqTrackerProcess [nid]
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

        True <- serviceProcessStillAlive mm (Node nid) Monitor.regularMonitor
        nn <- expect
        pr <- expect
        rg <- G.getGraph mm
        case runningService nn Monitor.regularMonitor rg of
          Just (ServiceProcess n) -> do True <- return $ n /= pr
                                        return ()
          Nothing -> return ()

  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable


testRemoteTable :: RemoteTable
testRemoteTable = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
                  remoteTable


withLocalNode :: Transport -> RemoteTable -> (LocalNode -> IO a) -> IO a
withLocalNode t rt = E.bracket  (newLocalNode t rt) closeLocalNode

withLocalNodes :: Int
               -> Transport
               -> RemoteTable
               -> ([LocalNode] -> IO a)
               -> IO a
withLocalNodes 0 _t _rt f = f []
withLocalNodes n t rt f = withLocalNode t rt $ \node ->
    withLocalNodes (n - 1) t rt (f . (node :))

runTest :: Int -> Int -> Int -> Transport -> RemoteTable
        -> ([LocalNode] -> Process ()) -> IO ()
runTest numNodes numReps _t tr rt action
    | Scheduler.schedulerIsEnabled = do
        (s,numReps') <- lookupEnv "DP_SCHEDULER_SEED" >>= \mx -> case mx of
          Nothing -> (,numReps) <$> randomIO
          Just s  -> return (read s,1)
        -- TODO: Fix leaks in n-t-inmemory and use the same transport for all
        -- tests, maybe.
        forM_ [1..numReps'] $ \i ->  withTmpDirectory $
          E.bracket createTransport closeTransport $
          \tr' -> do
            m <- timeout (7 * 60 * 1000000) $
              Scheduler.withScheduler (s + i) 1000 numNodes tr' rt' action
            maybe (error "Timeout") return m
          `E.onException`
            liftIO (hPutStrLn stderr $ "Failed with seed: " ++ show (s + i, i))
    | otherwise =
        withTmpDirectory $ withLocalNodes numNodes tr rt' $
          \(n : ns) -> do
            m <- timeout (7 * 60 * 1000000) $ runProcess n (action ns)
            maybe (error "Timeout") return m
  where
    rt' = Scheduler.__remoteTable rt
