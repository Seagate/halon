{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE LambdaCase     #-}
{-# LANGUAGE StandaloneDeriving #-}
-- | Module testing handling of notifications from SSPL and
-- notification interface related to systemd services and their
-- underlying process being restarted.
module HA.Castor.Story.ProcessRestart (mkTests) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Exception as E hiding (assert)
import           Control.Monad (unless)
import           Data.Binary (Binary)
import           Data.Foldable (find, for_)
import           Data.Function (fix)
import           Data.List (sort)
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics (Generic)
import qualified HA.Castor.Story.Tests as H
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Mero
import           HA.Replicator
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

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (_::AMQPException) -> return $ \_->
      [testSuccess "Process restart"  $ return ()]
    Right x -> do
      closeConnection x
      return $ \transport ->
        [ testSuccess "testSSPLFirst (disabled due to processCascadeRule)" $
          unless True $ testSSPLFirst transport pg
        , testSuccess "testMeroOnlineFirstSamePid" $
          testMeroOnlineFirstSamePid transport pg
        , testSuccess "testMeroOnlineFirstDiffPid" $
          testMeroOnlineFirstDiffPid transport pg
        , testSuccess "testNothingOnStarting" $
          testNothingOnStarting transport pg
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
doRestart :: (Typeable g, RGroup g)
          => Transport
          -> Proxy g
          -> M0.ProcessState
          -- ^ Starting state of the processes
          -> (M0.Process -> [M0.Service]
              -> ReceivePort NotificationMessage -> Process ())
          -- ^ Main test block
          -> IO ()
doRestart transport pg startingState runRestartTest =
  H.run transport pg interceptor [rule] test where
  interceptor _ _ = return ()

  test (TestArgs _ _ rc) rmq recv _ = do
    H.prepareSubscriptions rc rmq
    H.loadInitialData
    self <- getSelfPid
    nid <- getSelfNode
    _ <- promulgateEQ [nid] $ RuleHook self
    procs <- expectTimeout 5000000 :: Process (Maybe [(M0.Process, [M0.Service])])
    case procs of
      Just [(p, srvs)] -> runRestartTest p srvs recv
      _ -> fail $ "doRestart: expected single process in initial data but got "
               ++ show procs

  rule :: Definitions LoopState ()
  rule = defineSimple "testProcessRestart" $ \(HAEvent eid (RuleHook pid) _) -> do
    rg <- getLocalGraph
    let procs = [ (p, G.connectedTo p M0.IsParentOf rg :: [M0.Service])
                | (prof :: M0.Profile) <- G.connectedTo Cluster Has rg
                , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
                , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
                , (p :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
                ]
    for_ procs $ \(p, _) -> modifyGraph $ \rg' -> do
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
testSSPLFirst :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testSSPLFirst t pg = doRestart t pg M0.PSOnline $ \p srvs recv -> do
  nid <- getSelfNode
  promulgateWait (nid, mkRestartedNotification p)
  Just (Set nt) <- fmap notificationMessage <$> receiveChanTimeout 5000000 recv
  liftIO $ assertEqual "SSPL handler sets FAILED"
           [Note (M0.r_fid p) M0_NC_FAILED] nt

  promulgateWait (Set [Note (M0.fid p) M0_NC_ONLINE])
  Set nt' <- notificationMessage <$> receiveChan recv
  liftIO $ assertEqual "handleProcessOnline sets M0_NC_ONLINE"
           [Note (M0.r_fid p) M0_NC_ONLINE] nt'

-- |
-- * Process is in 'M0.PSOnline' state
-- * M0_NC_ONLINE comes first
-- * ONLINE sent to mero, mero pid set
-- * SSPL restart notification comes for the pid
-- * Nothing sent to mero
testMeroOnlineFirstSamePid :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testMeroOnlineFirstSamePid t pg = doRestart t pg M0.PSOnline $ \p srvs recv -> do
  nid <- getSelfNode
  promulgateWait (Set [Note (M0.fid p) M0_NC_ONLINE])
  Set nt <- H.nextNotificationFor (M0.fid p) recv
  let mkMsg k = Note (M0.fid k) M0_NC_ONLINE
  liftIO $ assertEqual "handleProcessOnline sets M0_NC_FAILED"
           (sort $ mkMsg p : map mkMsg srvs) (sort nt)
  promulgateWait (nid, mkRestartedNotification p)
  msg <- fmap notificationMessage <$> receiveChanTimeout 2000000 recv
  liftIO $ assertEqual "No message received" Nothing msg

-- |
-- * Process is in 'M0.PSOnline' state
-- * M0_NC_ONLINE comes first
-- * ONLINE sent to mero, mero pid set
-- * SSPL restart notification comes for different pid
-- * FAILED sent to mero
testMeroOnlineFirstDiffPid :: (Typeable g, RGroup g)
                           => Transport -> Proxy g -> IO ()
testMeroOnlineFirstDiffPid t pg = doRestart t pg M0.PSOnline $ \p srvs recv -> do
  nid <- getSelfNode
  promulgateWait (Set [Note (M0.r_fid p) M0_NC_ONLINE])
  Set nt <- H.nextNotificationFor (M0.fid p) recv
  let mkMsg k = Note (M0.fid k) M0_NC_ONLINE
  liftIO $ assertEqual "handleProcessOnline sets M0_NC_FAILED"
           (sort $ mkMsg p : map mkMsg srvs) (sort nt)
  let notification = (mkRestartedNotification p)
        { sensorResponseMessageSensor_response_typeService_watchdogPid = "1235" }

  promulgateWait (nid, notification)
  Set nt' <- H.nextNotificationFor (M0.fid p) recv
  liftIO $ assertEqual "SSPL handler sets M0_NC_ONLINE"
           [Note (M0.r_fid p) M0_NC_FAILED] nt'


-- |
-- * Process is in @'M0.PSStarting' 'Nothing'@ state
-- * M0_NC_ONLINE comes
-- * No notification is sent out
testNothingOnStarting :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testNothingOnStarting t pg = doRestart t pg M0.PSStarting $ \p _ recv -> do
  promulgateWait (Set [Note (M0.r_fid p) M0_NC_ONLINE])
  msg <- fix $ \go -> do
    fmap notificationMessage <$> receiveChanTimeout 2000000 recv >>= \case
      Nothing -> return Nothing
      Just s@(Set xs) -> case (find (\(Note f _) -> f == M0.fid p) xs) of
        Just _ -> return $ Just s
        Nothing -> go
  liftIO $ assertEqual "No message received" Nothing msg
