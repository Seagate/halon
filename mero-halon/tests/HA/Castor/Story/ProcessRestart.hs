{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE StandaloneDeriving #-}
-- | Module testing handling of notifications from SSPL and
-- notification interface related to systemd services and their
-- underlying process being restarted.
module HA.Castor.Story.ProcessRestart (mkTests) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Exception as E hiding (assert)
import           Data.Binary (Binary)
import           Data.Foldable (for_)
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics (Generic)
import qualified HA.Castor.Story.Tests as H
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Mero
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Services.Mero
import           Mero.ConfC (fidToStr)
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.AMQP
import           Network.CEP
import           Network.Transport
import           SSPL.Bindings
import           Test.Framework
import           Test.Tasty.HUnit (assertEqual)
import           TestRunner

mkTests :: IO (Transport -> [TestTree])
mkTests = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (_::AMQPException) -> return $ \_->
      [testSuccess "Process restart"  $ return ()]
    Right x -> do
      closeConnection x
      return $ \transport ->
        [ testSuccess "testSSPLFirst" $
          testSSPLFirst transport
        , testSuccess "testMeroOnlineFirstSamePid" $
          testMeroOnlineFirstSamePid transport
        , testSuccess "testMeroOnlineFirstDiffPid" $
          testMeroOnlineFirstDiffPid transport
        , testSuccess "testNothingOnStarting" $
          testNothingOnStarting transport
        ]

--------------------------------------------------------------------------------
-- Test primitives
--------------------------------------------------------------------------------

-- | Make a notification of the form that we'd receive from SSPL upon
-- service restart.
mkRestartedNotification :: M0.Process
                        -> SensorResponseMessageSensor_response_typeService_watchdog
mkRestartedNotification p =
  let fid' = fidToStr $ M0.r_fid p
      srvName = T.pack $ "m0d@" ++ fid' ++ ".service"
  in SensorResponseMessageSensor_response_typeService_watchdog
     { sensorResponseMessageSensor_response_typeService_watchdogService_state = "active"
     , sensorResponseMessageSensor_response_typeService_watchdogService_name = srvName
     , sensorResponseMessageSensor_response_typeService_watchdogPrevious_service_state = "inactive"
     , sensorResponseMessageSensor_response_typeService_watchdogService_substate = "active"
     , sensorResponseMessageSensor_response_typeService_watchdogPrevious_service_substate = "inactive"
     , sensorResponseMessageSensor_response_typeService_watchdogPid = "1234"
     , sensorResponseMessageSensor_response_typeService_watchdogPrevious_pid = "1233"
     }

-- | Used to fire internal test rules
newtype RuleHook = RuleHook ProcessId
  deriving (Generic, Typeable)
instance Binary RuleHook

-- | Generic test runner for failing processes
doRestart :: Transport
          -> M0.ProcessState
          -- ^ Starting state of the processes
          -> (M0.Process -> ReceivePort NotificationMessage -> Process ())
          -- ^ Main test block
          -> IO ()
doRestart transport startingState runRestartTest =
  H.run transport interceptor [rule] test where
  interceptor _ _ = return ()

  test (TestArgs _ _ rc) rmq recv = do
    H.prepareSubscriptions rc rmq
    H.loadInitialData
    self <- getSelfPid
    nid <- getSelfNode
    _ <- promulgateEQ [nid] $ RuleHook self
    procs <- expectTimeout 5000000 :: Process (Maybe [M0.Process])
    case procs of
      Just [p] -> runRestartTest p recv
      _ -> fail $ "doRestart: expected single process in initial data but got "
               ++ show procs

  rule :: Definitions LoopState ()
  rule = defineSimple "testProcessRestart" $ \(HAEvent eid (RuleHook pid) _) -> do
    rg <- getLocalGraph
    let procs = [ p | (prof :: M0.Profile) <- G.connectedTo Cluster Has rg
                    , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
                    , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
                    , (p :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
                ]
    for_ procs $ \p -> modifyGraph $ \rg' -> do
      G.connectUniqueFrom p Is startingState rg'
    liftProcess $ usend pid procs
    messageProcessed eid


--------------------------------------------------------------------------------
-- Actual tests
--------------------------------------------------------------------------------

-- |
-- * Process is in starting state waiting for no particular pid
-- * SSPL restart notification comes
-- * M0_NC_ONLINE notification comes
-- * M0_NC_FAILED and M0_NC_ONLINE are sent to mero
testSSPLFirst :: Transport -> IO ()
testSSPLFirst t = doRestart t M0.PSOnline $ \p recv -> do
  nid <- getSelfNode
  promulgateWait (nid, mkRestartedNotification p)
  Set nt <- notificationMessage <$> receiveChan recv
  liftIO $ assertEqual "SSPL handler sets FAILED"
           [Note (M0.r_fid p) M0_NC_FAILED] nt

  promulgateWait (Set [Note (M0.r_fid p) M0_NC_ONLINE])
  Set nt' <- notificationMessage <$> receiveChan recv
  liftIO $ assertEqual "handleProcessOnline sets M0_NC_ONLINE"
           [Note (M0.r_fid p) M0_NC_ONLINE] nt'

-- |
-- * Process is in 'M0.PSOnline' state
-- * M0_NC_ONLINE comes first
-- * ONLINE sent to mero, mero pid set
-- * SSPL restart notification comes for the pid
-- * Nothing sent to mero
testMeroOnlineFirstSamePid :: Transport -> IO ()
testMeroOnlineFirstSamePid t = doRestart t M0.PSOnline $ \p recv -> do
  nid <- getSelfNode
  promulgateWait (Set [Note (M0.r_fid p) M0_NC_ONLINE])
  Set nt <- notificationMessage <$> receiveChan recv
  liftIO $ assertEqual "handleProcessOnline sets M0_NC_FAILED"
           [Note (M0.r_fid p) M0_NC_ONLINE] nt
  promulgateWait (nid, mkRestartedNotification p)
  msg <- fmap notificationMessage <$> receiveChanTimeout 2000000 recv
  liftIO $ assertEqual "No message received" Nothing msg

-- |
-- * Process is in 'M0.PSOnline' state
-- * M0_NC_ONLINE comes first
-- * ONLINE sent to mero, mero pid set
-- * SSPL restart notification comes for different pid
-- * FAILED sent to mero
testMeroOnlineFirstDiffPid :: Transport -> IO ()
testMeroOnlineFirstDiffPid t = doRestart t M0.PSOnline $ \p recv -> do
  nid <- getSelfNode
  promulgateWait (Set [Note (M0.r_fid p) M0_NC_ONLINE])
  Set nt <- notificationMessage <$> receiveChan recv
  liftIO $ assertEqual "handleProcessOnline sets M0_NC_FAILED"
           [Note (M0.r_fid p) M0_NC_ONLINE] nt
  let notification = (mkRestartedNotification p)
        { sensorResponseMessageSensor_response_typeService_watchdogPid = "1235" }

  promulgateWait (nid, notification)
  Set nt' <- notificationMessage <$> receiveChan recv
  liftIO $ assertEqual "SSPL handler sets M0_NC_ONLINE"
           [Note (M0.r_fid p) M0_NC_FAILED] nt'


-- |
-- * Process is in @'M0.PSStarting' 'Nothing'@ state
-- * M0_NC_ONLINE comes
-- * No notification is sent out
testNothingOnStarting :: Transport -> IO ()
testNothingOnStarting t = doRestart t M0.PSStarting $ \p recv -> do
  promulgateWait (Set [Note (M0.r_fid p) M0_NC_ONLINE])
  msg <- fmap notificationMessage <$> receiveChanTimeout 2000000 recv
  liftIO $ assertEqual "No message received" Nothing msg
