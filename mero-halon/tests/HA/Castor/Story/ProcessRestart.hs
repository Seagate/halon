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
import           Mero.ConfC (fidToStr, Fid(..), ServiceType(..))
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
        [ testSuccess "testSSPLFirst" $
          testSSPLFirst transport pg
        , testSuccess "testMeroOnlineFirst" $
          testMeroOnlineFirst transport pg
        ]

--------------------------------------------------------------------------------
-- Test primitives
--------------------------------------------------------------------------------

-- | The PID of the process used throughout tests.
testProcessPid :: Int
testProcessPid = 1234

testProcessNewPid :: Int
testProcessNewPid = 6666

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
     , sensorResponseMessageSensor_response_typeService_watchdogPid = T.pack $ show testProcessNewPid
     , sensorResponseMessageSensor_response_typeService_watchdogPrevious_pid = T.pack $ show testProcessPid
     }

-- | Make a process event notification that 'ruleProcessOnline' expects.
mkProcessStartedNotification :: M0.Process
                             -> M0.PID
                             -> (HAMsgMeta, ProcessEvent)
mkProcessStartedNotification p (M0.PID pid) = (meta, event)
  where
    nullFid = Fid 0 0
    meta = HAMsgMeta { _hm_fid = M0.fid p
                     , _hm_source_process = nullFid
                     , _hm_source_service = nullFid
                     , _hm_time = 0 }
    event = ProcessEvent { _chp_event = TAG_M0_CONF_HA_PROCESS_STARTED
                         , _chp_pid = fromIntegral pid }



-- | Used to fire internal test rules
newtype RuleHook = RuleHook ProcessId
  deriving (Generic, Typeable)
instance Binary RuleHook

-- | Generic test runner for failing processes. Attaches the given
-- starting state and 'testProcessPid' to the process in RG before
-- running the given test on it.
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
    for_ procs $ \(p, _) -> modifyGraph $
      G.connectUniqueFrom p Is startingState
      . G.connectUniqueFrom p Has (M0.PID testProcessPid)


    -- Attach a dummy online process so that notifications during the
    -- tests are received even if we have our main test process as
    -- failed.
    let incFid (Fid low high) = Fid low (high + 50)
        (p, srvs) : _ = procs
        (n :: M0.Node) : _ = G.connectedFrom M0.IsParentOf p rg

        newProc = p { M0.r_fid = incFid $ M0.r_fid p }
        newSrvs = [ s { M0.s_fid = incFid $ M0.s_fid s }
                  | s <- srvs, M0.s_type s /= CST_RMS ]

    modifyGraph $
      G.connectUniqueFrom newProc Is M0.PSOnline
      . (\g0 -> foldr (G.connect newProc M0.IsParentOf) g0 newSrvs)
      . G.connect n M0.IsParentOf newProc

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
  let mkMsg k t' = Note (M0.fid k) t'
  promulgateWait (nid, mkRestartedNotification p)
  Set nt <- H.nextNotificationFor (M0.fid p) recv
  liftIO $ assertEqual "SSPL handler sets process to failed"
           (sort $ mkMsg p M0_NC_FAILED : map (`mkMsg` M0_NC_ONLINE) srvs) (sort nt)

  promulgateWait $ mkProcessStartedNotification p (M0.PID testProcessNewPid)
  Set nt' <- H.nextNotificationFor (M0.fid p) recv
  liftIO $ assertEqual "ruleProcessOnline sets process to online"
           (sort $ mkMsg p M0_NC_ONLINE : map (`mkMsg` M0_NC_ONLINE) srvs) (sort nt')

-- |
-- * Process is in 'M0.PSOnline' state
-- * Process started event for process with new PID comes.
-- * A restart is assumed, process is set to starting
-- * SSPL restart notification comes for the new pid
-- * Process is set to online
testMeroOnlineFirst :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testMeroOnlineFirst t pg = doRestart t pg M0.PSOnline $ \p srvs recv -> do
  nid <- getSelfNode
  let mkMsg k t' = Note (M0.fid k) t'
  promulgateWait $ mkProcessStartedNotification p (M0.PID testProcessNewPid)
  Set nt <- H.nextNotificationFor (M0.fid p) recv
  liftIO $ assertEqual "ruleProcessOnline sets process to online"
           (sort $ mkMsg p M0_NC_FAILED : map (`mkMsg` M0_NC_ONLINE) srvs) (sort nt)

  promulgateWait (nid, mkRestartedNotification p)
  Set nt' <- H.nextNotificationFor (M0.fid p) recv
  liftIO $ assertEqual "SSPL handler sets process to online"
           (sort $ mkMsg p M0_NC_ONLINE : map (`mkMsg` M0_NC_ONLINE) srvs) (sort nt')
