-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module HA.RecoveryCoordinator.Mero.Tests
  ( testDriveAddition
  , testHostAddition
  , testServiceRestarting
  , testServiceNotRestarting
  , testEQTrimming
  , testDecisionLog
  ) where

import Prelude hiding ((<$>), (<*>))
import Test.Framework

import HA.Resources
import HA.Resources.Mero
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.EventQueue
import HA.EventQueue.Definitions
import HA.EventQueue.Producer (promulgateEQ)
import HA.Multimap.Implementation
import HA.Multimap.Process
import HA.NodeUp (nodeUp)
import HA.Replicator
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import qualified HA.ResourceGraph as G
import HA.Service
  ( Configuration
  , Service
  , ServiceFailed(..)
  , ServiceProcess(..)
  , ServiceStartRequest(..)
  , Owns(..)
  , encodeP
  , runningService
  )
import qualified HA.Services.Dummy as Dummy
import qualified HA.Services.DecisionLog as DLog
import RemoteTables ( remoteTable )

import qualified SSPL.Bindings as SSPL

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( remotableDecl, mkStatic )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Network.Transport (Transport)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ( first, second )
import Control.Concurrent (threadDelay)
import Control.Monad (forM_, void)

import qualified Data.Attoparsec.ByteString.Char8 as Atto
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Data.Defaultable
import Data.List (isInfixOf)

import System.IO

import Network.CEP (Published(..), Sub(..), simpleSubscribe)

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
  send eq rc
  forM_ [mm, rc] $ \them -> send them ()
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
        liftIO $ threadDelay 500000
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
                     liftIO $ threadDelay 250000
                     loop (i + 1)
                   _ -> return False

-- | Test that the recovery co-ordinator can successfully restart a service
--   upon notification of failure.
--   This test does not verify the appropriate detection of service failure,
--   nor does it verify that the 'one service instance per node' constraint
--   is not violated.
testServiceRestarting :: Transport -> IO ()
testServiceRestarting transport = do
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"Starting service dummy"   -> send self str
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        nodeUp ([nid], 2000000)
        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest (Node nid) Dummy.dummy
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
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"Starting service dummy"   -> send self str
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        nodeUp ([nid], 2000000)
        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest (Node nid) Dummy.dummy
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
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
        nid <- getSelfNode

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        simpleSubscribe eq (Sub :: Sub TrimDone)
        (mm,_) <- runRC (eq, IgnitionArguments [nid]) rGroup

        nodeUp ([nid], 2000000)
        Published TrimDone _ <- expect
        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest (Node nid) Dummy.dummy
            (Dummy.DummyConf $ Configured "Test 1")

        Published TrimDone _ <- expect

        pid <- getServiceProcessPid mm (Node nid) Dummy.dummy
        _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy
                                                          pid

        Published TrimDone _ <- expect
        say $ "Everything got trimmed"
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable


-- | Test that the recovery co-ordinator successfully adds a host to the
--   resource graph.
testHostAddition :: Transport -> IO ()
testHostAddition transport = do
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"Starting service dummy"   -> send self str
            str' | "Registered host" `isInfixOf` str' -> send self ("Host" :: String)
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm, _) <- runRC (eq, IgnitionArguments [nid]) rGroup

        nodeUp ([nid], 2000000)

        -- Send host update message to the RC
        promulgateEQ [nid] (nid, mockEvent) >>= (flip withMonitor) wait
        "Host" :: String <- expect

        graph <- G.getGraph mm
        let host = Host "mockhost"
            int = Interface "192.168.0.1"
            node = Node nid
        assert $ G.memberResource host graph
        assert $ G.memberResource int graph
        assert $ G.memberEdge (G.Edge host Runs node) graph

  where
    wait = void (expect :: Process ProcessMonitorNotification)
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
    mockEvent = SSPL.SensorResponseSensor_response_typeHost_update
                { SSPL.sensorResponseSensor_response_typeHost_updateRunningProcessCount = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateIfData              = Just [mockIf]
                , SSPL.sensorResponseSensor_response_typeHost_updateUname               = Just "mockhost"
                , SSPL.sensorResponseSensor_response_typeHost_updateUpTime              = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateLocalMountData      = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateFreeMem             = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateLoggedInUsers       = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateTotalMem            = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateProcessCount        = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateBootTime            = Nothing
                , SSPL.sensorResponseSensor_response_typeHost_updateCpuData             = Nothing
                }
    mockIf = SSPL.SensorResponseSensor_response_typeHost_updateIfDataItem
              { SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemTrafficIn         = Nothing
              , SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemNetworkErrors     = Nothing
              , SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemTrafficOut        = Nothing
              , SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemDroppedPacketsIn  = Nothing
              , SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemPacketsIn         = Nothing
              , SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemDopppedPacketsOut = Nothing
              , SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemIfId              = Just "192.168.0.1"
              , SSPL.sensorResponseSensor_response_typeHost_updateIfDataItemPacketsOut        = Nothing
              }

-- | Test that the recovery co-ordinator successfully adds a drive to the RG,
--   and updates its status accordingly.
testDriveAddition :: Transport -> IO ()
testDriveAddition transport = do
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"Starting service dummy"   -> send self str
            str' | "Registered drive" `isInfixOf` str' -> send self ("Drive" :: String)
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm, _) <- runRC (eq, IgnitionArguments [nid]) rGroup

        nodeUp ([nid], 2000000)

        -- Send host update message to the RC
        promulgateEQ [nid] (nid, mockEvent "online") >>= (flip withMonitor) wait
        "Drive" :: String <- expect

        graph <- G.getGraph mm
        let enc = Enclosure "enc1"
            drive = StorageDevice 1
            status = StorageDeviceStatus "online"
        assert $ G.memberResource enc graph
        assert $ G.memberResource drive graph
        assert $ G.memberResource status graph
        assert $ G.memberEdge (G.Edge enc Has drive) graph
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
    mockEvent status =
      SSPL.SensorResponseSensor_response_typeDisk_status_drivemanager
        { SSPL.sensorResponseSensor_response_typeDisk_status_drivemanagerEnclosureSN = "enc1"
        , SSPL.sensorResponseSensor_response_typeDisk_status_drivemanagerDiskNum = 1
        , SSPL.sensorResponseSensor_response_typeDisk_status_drivemanagerDiskStatus = status
        }

data DLogLine =
    DLogLine
    { dlogRuleId  :: !B.ByteString
    , dlogPidStr  :: !String
    , dlogCounter :: !Int
    , dlogHops    :: ![String]
    , dlogEntries :: ![(B.ByteString, String)]
    } deriving Show

parsePID :: Atto.Parser B.ByteString
parsePID = Atto.takeWhile (\c -> c /= ',' && c /= ']')

parsePIDStr :: Atto.Parser String
parsePIDStr = fmap B8.unpack parsePID

parseEntry :: Atto.Parser (B.ByteString, String)
parseEntry = do
    _   <- Atto.string "context="
    ctx <- Atto.takeWhile (/= ';')
    _   <- Atto.string ";log=\""
    v   <- Atto.takeWhile (/= '"')
    _   <- Atto.char '"'
    return (ctx, B8.unpack v)

parseEntries :: Atto.Parser [(B.ByteString, String)]
parseEntries = parseEntry `Atto.sepBy1'` Atto.endOfLine

parseDLogLine :: Atto.Parser DLogLine
parseDLogLine = do
    _      <- Atto.string "rule-id="
    ruleid <- Atto.takeWhile (/= ';')
    _      <- Atto.string ";inputs=eventId=EventId {eventNodeId = "
    pid    <- parsePIDStr
    _      <- Atto.string ", eventCounter = "
    cnt    <- Atto.decimal
    _      <- Atto.string "};eventHops=["
    hs     <- parsePIDStr `Atto.sepBy1'` Atto.char ','
    _      <- Atto.string "];;entries="
    es     <- parseEntries
    return DLogLine
           { dlogRuleId   = ruleid
           , dlogPidStr   = pid
           , dlogCounter  = cnt
           , dlogHops     = hs
           , dlogEntries  = es
           }

parseDLogLines :: Atto.Parser [DLogLine]
parseDLogLines = parseDLogLine `Atto.sepBy1'` Atto.endOfLine

readFileContents :: FilePath -> Process B.ByteString
readFileContents path = liftIO $ do
    h <- openFile path ReadMode
    B.hGetContents h

logExpectations :: ProcessId -> [DLogLine] -> Process ()
logExpectations eq xs@[x,y] = do
    if dlogRuleId x == "service-started" &&
       dlogCounter x == 1 &&
       dlogEntries x == [("started", "Service decision-log started")] &&
       dlogHops x    == [show eq] &&
       dlogRuleId y == "service-started" &&
       dlogCounter y == 1 &&
       dlogEntries y == [("started", "Service dummy started")] &&
       dlogHops y == [show eq]
       then return ()
       else error $ "Wrong expectation: " ++ show xs
logExpectations _ xs =
    error $ "Expected 2 lines, got " ++ show (length xs) ++ " instead"

confirmDead :: ProcessId -> Process ()
confirmDead pid =
    receiveWait [ matchIf (\(ProcessMonitorNotification _ p _) -> p == pid)
                          (\_ -> return ()) ]

testDecisionLog :: Transport -> IO ()
testDecisionLog transport = do
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"entries submitted" -> send self str
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        (mm, rc) <- runRC (eq, IgnitionArguments [nid]) rGroup

        nodeUp ([nid], 2000000)
        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest (Node nid) DLog.decisionLog
            (DLog.DecisionLogConf "./dlog.log")

        ("entries submitted" :: String) <- expect

        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest (Node nid) Dummy.dummy
            (Dummy.DummyConf $ Configured "Test 1")

        ("entries submitted" :: String) <- expect

        rg <- G.getGraph mm
        let sp :: ServiceProcess DLog.DecisionLogConf
            sp = case G.connectedFrom Owns DLog.decisionLogServiceName rg of
                   [sp'] -> sp'
                   _     -> error "Can't retrieve DLog PID"
            ServiceProcess dlogpid = sp

        _ <- monitor rc
        _ <- monitor dlogpid
        kill rc "I killed you RC"
        kill dlogpid "We want to access your log file"

        confirmDead rc
        confirmDead dlogpid
        bs <- readFileContents "./dlog.log"
        let res = Atto.parseOnly parseDLogLines bs
        case res of
          Left e   -> error $ "dlog parsing error: " ++ e
          Right xs -> logExpectations eq xs
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
