{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module HA.Castor.Story.Tests where

import HA.EventQueue.Producer
import HA.EventQueue.Types
import HA.NodeUp (nodeUp)
import HA.RecoveryCoordinator.Actions.Castor.Cluster (notifyOnClusterTransition)
import HA.RecoveryCoordinator.Actions.Mero.Conf (encToM0Enc)
import HA.RecoveryCoordinator.Actions.Mero.Failure.Dynamic
   ( findRealObjsInPVer
   , findFailableObjs
   )
import HA.RecoveryCoordinator.Events.Service
import qualified HA.RecoveryCoordinator.Actions.Service as Service
import HA.RecoveryCoordinator.Castor.Drive
import HA.RecoveryCoordinator.Castor.Drive.Actions
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Castor.Initial
  ( InitialData(..)
  , M0Globals(..)
  , FailureSetScheme(Dynamic)
  )
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.Multimap
import HA.Encode
import HA.Services.Mero
import HA.Services.Mero.Types
import HA.Services.SSPL
import HA.Services.SSPL.Rabbit
import HA.Services.SSPL.LL.Resources
import HA.RecoveryCoordinator.Mero
import HA.Replicator


import Mero.ConfC (Fid)
import Mero.Notification
import Mero.Notification.HAState

import RemoteTables (remoteTable)

import SSPL.Bindings

import Control.Arrow ((&&&))
import Control.Monad (forM_, replicateM_, void)
import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Node
import Control.Exception as E hiding (assert)

import Data.Aeson (decode, encode)
import qualified Data.Aeson.Types as Aeson
import Data.Binary (Binary)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (find)
import Data.Function (fix)
import Data.Hashable (Hashable)
import Data.Proxy
import qualified Data.Set as S
import Data.Typeable
import Data.Text (pack)
import Data.Defaultable
import qualified Data.UUID as UUID
import Data.UUID.V4 (nextRandom)
import Mero.ConfC (Fid(..))
import HA.Resources.HalonVars

import GHC.Generics (Generic)

import Network.AMQP
import Network.CEP
import Network.Transport

import Test.Framework
import Test.Tasty.HUnit (Assertion, assertEqual, assertBool, assertFailure)
import TestRunner
import Helper.InitialData
import Helper.SSPL
import Helper.Environment (systemHostname, testListenName)

debug :: String -> Process ()
debug = say . ("debug: " ++)

myRemoteTable :: RemoteTable
myRemoteTable = TestRunner.__remoteTableDecl remoteTable

newtype MockM0 = MockM0 DeclareMeroChannel
  deriving (Binary, Generic, Hashable, Typeable)

mockMeroConf :: MeroConf
mockMeroConf = MeroConf ""
                        (Fid 0x7000000000000001 0x1)
                        (Fid 0x7200000000000001 0x18)
                        (Fid 0x7200000000000001 0x25)
                        (Fid 0x7200000000000001 0x26)
                        (_hv_keepalive_frequency defaultHalonVars)
                        (_hv_keepalive_timeout defaultHalonVars)
                        (MeroKernelConf UUID.nil)

data MarkDriveFailed = MarkDriveFailed deriving (Generic, Typeable)
instance Binary MarkDriveFailed

ssplTimeout :: Int
ssplTimeout = 10*1000000

data ThatWhichWeCallADisk = ADisk {
    aDiskSD :: StorageDevice -- ^ Has a storage device
  , aDiskMero :: Maybe (M0.SDev) -- ^ Maybe has a corresponding Mero device
  , aDiskSN :: String -- ^ Has a serial number
  , aDiskPath :: String -- ^ Has a path
  , aDiskWWN :: String -- ^ Has a WWN
}

newMeroChannel :: ProcessId
               -> Process ( ReceivePort NotificationMessage
                          , ReceivePort ProcessControlMsg
                          , MockM0
                          )
newMeroChannel pid = do
  (sd, recv) <- newChan
  (cc, recv1) <- newChan
  let sdChan   = TypedChannel sd
      connChan = TypedChannel cc
      notfication = MockM0
              $ DeclareMeroChannel pid sdChan connChan
  return (recv, recv1, notfication)

testRules :: Definitions LoopState ()
testRules = do
  defineSimple "register-mock-service" $
    \(HAEvent eid (MockM0 dc@(DeclareMeroChannel _ _ _)) _) -> do
      rg <- getLocalGraph
      nid <- liftProcess $ getSelfNode
      let node = Node nid
          host = Host systemHostname
          procs = [ proc
                  | Just (m0cont :: M0.Controller) <- [G.connectedFrom M0.At host rg]
                  , Just (m0node :: M0.Node) <- [G.connectedFrom M0.IsOnHardware m0cont rg]
                  , proc <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
                  ]
      -- We have to mark the process as online in order for our mock mero
      -- service to be sent notifications for them.
      phaseLog "debug:procs" $ show procs
      forM_ procs $ \proc -> do
        modifyGraph $ setState proc M0.PSOnline
      -- Also mark the cluster disposition as ONLINE.
      modifyGraph $ G.connect Cluster Has M0.ONLINE
      -- Calculate cluster status.
      notifyOnClusterTransition Nothing
      locateNodeOnHost node host
      Service.register node m0d mockMeroConf
      void . liftProcess $ promulgateEQ [nid] dc
      messageProcessed eid
  defineSimple "mark-disk-failed" $ \(HAEvent eid MarkDriveFailed _) -> do
      rg <- getLocalGraph
      case G.getResourcesOfType rg of
        (sd:_) -> updateDriveStatus sd "HALON-FAILED" "MERO-Timeout"
        [] -> return ()
      messageProcessed eid

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e::AMQPException) -> return $ \_->
      [testSuccess ("Drive failure tests disabled (can't connect to rabbitMQ):"++show e)  $ return ()]
    Right x -> do
      closeConnection x
      return $ \transport ->
        [ testSuccess "Drive failure, successful reset and smart test success" $
          testDiskFailure transport pg
        , testSuccess "Drive failure, repeated attempts to reset, hitting reset limit" $
          testHitResetLimit transport pg
        , testSuccess "Drive failure, successful reset, failed smart test" $
          testFailedSMART transport pg
        , testSuccess "Drive failure, second drive fails whilst handling to reset attempt" $
          testSecondReset transport pg
        , testSuccess "Drive failure removal reported by SSPL" $
          testDriveRemovedBySSPL transport pg
        , testSuccess "Metadata drive failure reported by IEM" $
          testMetadataDriveFailed transport pg
        , testSuccess "Halon sends list of failed drives at SSPL start" $
          testGreeting transport pg
        , testSuccess "Halon powers down disk on failure" $
          testDrivePoweredDown transport pg
        , testSuccess "RAID reassembles after expander reset" $
          testExpanderResetRAIDReassemble transport pg
        ]

run :: (Typeable g, RGroup g)
    => Transport
    -> Proxy g
    -> (ProcessId -> String -> Process ()) -- interceptor callback
    -> [Definitions LoopState ()]
    -> (    TestArgs
         -> ProcessId
         -> ReceivePort NotificationMessage
         -> ReceivePort ProcessControlMsg
         -> Process ()
       ) -- actual test
    -> Assertion
run transport pg interceptor extraRules test =
  runTest 2 20 15000000 transport myRemoteTable $ \[n] -> do
    self <- getSelfPid
    nid <- getSelfNode
    withTrackingStation pg (testRules:extraRules) $ \ta -> do
      nodeUp ([nid], 1000000)
      registerInterceptor $ \string ->
        case string of
          str@"Starting service sspl"   -> usend self str
          x -> interceptor self x

      subscribe (ta_rc ta) (Proxy :: Proxy (HAEvent InitialData))
      loadInitialData

      startSSPLService (ta_rc ta)
      debug "Started SSPL service"
      (meroRP, meroCP) <- startMeroServiceMock (ta_rc ta)
      debug "Started Mero mock service"
      rmq <- spawnMockRabbitMQ self
      debug "Started mock RabbitMQ service."
      -- Run the test
      debug "About to run the test"

      test ta rmq meroRP meroCP
      say "Test finished"

      -- Tear down the test
      _ <- promulgateEQ [localNodeId n] $ encodeP $
            ServiceStopRequest (Node $ localNodeId n) sspl
      _ <- receiveTimeout 1000000 []
      unlink rmq
      kill rmq "end of game"
  where
    startSSPLService :: ProcessId -> Process ()
    startSSPLService rc = do
      subscribe rc (Proxy :: Proxy (HAEvent DeclareChannels))
      nid <- getSelfNode
      let conf =
            SSPLConf (ConnectionConf (Configured "localhost")
                                        (Configured "/")
                                        ("guest")
                                        ("guest"))
                     (SensorConf (BindConf (Configured "sspl_halon")
                                                (Configured "sspl_ll")
                                                (Configured "sspl_dcsque")))
                     (ActuatorConf (BindConf (Configured "sspl_iem")
                                                (Configured "sspl_ll")
                                                (Configured "sspl_iem"))
                                   (BindConf (Configured "halon_sspl")
                                                (Configured "sspl_ll")
                                                (Configured "halon_sspl"))
                                   (BindConf (Configured "sspl_command_ack")
                                                (Configured "halon_ack")
                                                (Configured "sspl_command_ack"))
                                   (Configured 1000000))

          msg = ServiceStartRequest Start (HA.Resources.Node nid) sspl conf []

      _ <- promulgateEQ [nid] $ encodeP msg
      ("Starting service sspl" :: String) <- expect
      _ <- expect :: Process (Published (HAEvent DeclareChannels))

      return ()

    startMeroServiceMock :: ProcessId
                         -> Process ( ReceivePort NotificationMessage
                                    , ReceivePort ProcessControlMsg
                                    )
    startMeroServiceMock rc = do
      subscribe rc (Proxy :: Proxy (HAEvent DeclareMeroChannel))
      nid <- getSelfNode
      pid <- getSelfPid
      (recv, recvc, channel) <- newMeroChannel pid
      _ <- promulgateEQ [nid] channel
      _ <- expect :: Process (Published (HAEvent DeclareMeroChannel))
      return (recv, recvc)

    spawnMockRabbitMQ :: ProcessId -> Process ProcessId
    spawnMockRabbitMQ self = do
      pid <- spawnLocal $ do
        link self
        rabbitMQProxy $ ConnectionConf (Configured "localhost")
                                       (Configured "/")
                                       ("guest")
                                       ("guest")
      link pid
      return pid

loadInitialData :: Process ()
loadInitialData = let
    init_msg = initialData systemHostname testListenName 1 12 defaultGlobals
  in do
    debug "loadInitialData"
    nid <- getSelfNode
    -- We populate the graph with confc context.
    _ <- promulgateEQ [nid] init_msg
    _ <- expect :: Process (Published (HAEvent InitialData))
    return ()


findSDev :: G.Graph -> Process ThatWhichWeCallADisk
findSDev rg =
  let dvs = [ ADisk storage (Just sdev) serial path wwn
            | sdev <- G.getResourcesOfType rg :: [M0.SDev]
            , Just (disk :: M0.Disk) <- [G.connectedTo sdev M0.IsOnHardware rg]
            , Just (storage :: StorageDevice) <- [G.connectedTo disk M0.At rg]
            , DISerialNumber serial <- G.connectedTo storage Has rg
            , DIPath path <- G.connectedTo storage Has rg
            , DIWWN wwn <- G.connectedTo storage Has rg
            ]
  in case dvs of
    dv:_ -> return dv
    _    -> do liftIO $ assertFailure "Can't find a M0.SDev or its serial number"
               error "Unreachable"

find2SDev :: G.Graph -> Process ThatWhichWeCallADisk
find2SDev rg =
  let dvs = [ ADisk storage (Just sdev) serial path wwn
            | sdev <- G.getResourcesOfType rg :: [M0.SDev]
            , Just (disk :: M0.Disk) <- [G.connectedTo sdev M0.IsOnHardware rg]
            , Just (storage :: StorageDevice) <- [G.connectedTo disk M0.At rg]
            , DISerialNumber serial <- G.connectedTo storage Has rg
            , DIPath path <- G.connectedTo storage Has rg
            , DIWWN wwn <- G.connectedTo storage Has rg
            ]
  in case dvs of
    _:dv:_ -> return dv
    _    -> do liftIO $ assertFailure "Can't find a second M0.SDev or its serial number"
               error "Unreachable"

devAttrs :: StorageDevice -> G.Graph -> [StorageDeviceAttr]
devAttrs sd rg = G.connectedTo sd Has rg

-- | Check if specified device have RemovedAt attribute.
checkStorageDeviceRemoved :: String -> Int -> G.Graph -> Bool
checkStorageDeviceRemoved enc idx rg = not . Prelude.null $
  [ () | dev  <- G.connectedTo (Enclosure enc) Has rg :: [StorageDevice]
       , any (==(DIIndexInEnclosure idx))
             (G.connectedTo dev Has rg :: [DeviceIdentifier])
       , any (==SDRemovedAt)
             (G.connectedTo dev Has rg :: [StorageDeviceAttr])
       ]

isPowered :: StorageDeviceAttr -> Bool
isPowered (SDPowered x) = x
isPowered _             = False

expectNodeMsg :: Int -> Process (Maybe ActuatorRequestMessageActuator_request_typeNode_controller)
expectNodeMsg = (fmap (fmap snd)) . expectNodeMsgUid

expectNodeMsgUid :: Int -> Process (Maybe (Maybe UUID, ActuatorRequestMessageActuator_request_typeNode_controller))
expectNodeMsgUid = expectActuatorMsg
  (actuatorRequestMessageActuator_request_typeNode_controller
  . actuatorRequestMessageActuator_request_type
  . actuatorRequestMessage
  )

expectLoggingMsg :: Int -> Process (Either String ActuatorRequestMessageActuator_request_typeLogging)
expectLoggingMsg = expectActuatorMsg'
  ( actuatorRequestMessageActuator_request_typeLogging
  . actuatorRequestMessageActuator_request_type
  . actuatorRequestMessage
  )


expectActuatorMsg :: (ActuatorRequest -> Maybe b) -> Int -> Process (Maybe (Maybe UUID, b))
expectActuatorMsg f t = do
    expectTimeout t >>= \case
      Just (MQMessage _ msg) -> return $ pull2nd . (getUUID &&& f) =<< (decode . LBS.fromStrict $ msg)
      Nothing -> do liftIO $ assertFailure "No message delivered to SSPL."
                    undefined
  where
    getUUID arm = do
      uid_s <- actuatorRequestMessageSspl_ll_msg_headerUuid
                . actuatorRequestMessageSspl_ll_msg_header
                . actuatorRequestMessage
                $ arm
      UUID.fromText uid_s
    pull2nd :: (a, Maybe b) -> Maybe (a,b)
    pull2nd (x, Just y) = Just (x,y)
    pull2nd (_, Nothing) = Nothing


expectActuatorMsg' :: (ActuatorRequest -> Maybe b) -> Int -> Process (Either String b)
expectActuatorMsg' f t = do
  expectTimeout t >>= \case
    Just (MQMessage _ msg) -> return $ case f =<< (decode . LBS.fromStrict $ msg) of
         Nothing -> Left (BS8.unpack msg)
         Just x  -> Right x
    Nothing -> do liftIO $ assertFailure "No message delivered to SSPL."
                  undefined

nextNotificationFor :: Fid -> ReceivePort NotificationMessage -> Process Set
nextNotificationFor fid recv = fix $ \go -> do
  nm <- receiveChan recv
  let s@(Set notes) = notificationMessage nm
  forM_ (notificationRecipients nm) $ promulgateWait . NotificationAck (notificationEpoch nm)
  case (find (\(Note f _) -> f == fid) notes) of
    Just _ -> return s
    Nothing -> do
      debug $ "Ignoring notification: " ++ show s ++ " looking for " ++ show fid
      go
--------------------------------------------------------------------------------
-- Test primitives
--------------------------------------------------------------------------------

prepareSubscriptions :: ProcessId -> ProcessId -> Process ()
prepareSubscriptions rc rmq = do
  subscribe rc (Proxy :: Proxy (HAEvent InitialData))
  subscribe rc (Proxy :: Proxy CommandAck)
  subscribe rc (Proxy :: Proxy (HAEvent ResetAttempt))

  -- Subscribe to SSPL channels
  usend rmq . MQSubscribe "halon_sspl" =<< getSelfPid
  usend rmq $ MQBind "halon_sspl" "halon_sspl" "sspl_ll"

loadInitialDataMod :: (InitialData -> InitialData)
                   -> Process ()
loadInitialDataMod f = let
    init_msg = f $ defaultInitialData
  in do
    nid <- getSelfNode
    -- We populate the graph with confc context.
    _ <- promulgateEQ [nid] init_msg
    _ <- expect :: Process (Published (HAEvent InitialData))
    return ()

mkSDevFailedMsg :: M0.SDev -> HAMsg StobIoqError
mkSDevFailedMsg sdev = HAMsg stob_ioq_error msg_meta
  where
    stob_ioq_error = StobIoqError
      { _sie_conf_sdev = M0.d_fid sdev
      , _sie_stob_id = StobId (Fid 0x0000000000000000 0x01) (Fid 0x0000000000000000 0x02)
      , _sie_fd = 42
      , _sie_opcode = SIO_INVALID
      , _sie_rc = 1
      , _sie_offset = 43
      , _sie_size = 44
      , _sie_bshift = 45
      }
    msg_meta = HAMsgMeta
      { _hm_fid = M0.d_fid sdev
      , _hm_source_process = Fid 0x7200000000000000 0x99
      , _hm_source_service = Fid 0x7300000000000000 0x99
      , _hm_time = 0
      }


-- | Fail a drive (via Mero notification)
failDrive :: ReceivePort NotificationMessage -> ThatWhichWeCallADisk -> Process ()
failDrive _ (ADisk _ Nothing _ _ _) = error "Cannot fail a non-Mero disk."
failDrive recv (ADisk _ (Just sdev) serial _ _) = do
  let tserial = pack serial
  debug "failDrive"
  nid <- getSelfNode
  -- We a drive failure note to the RC.
  _ <- promulgateEQ [nid] (mkSDevFailedMsg sdev)
  -- Mero should be notified that the drive should be transient.
  Set msg <- nextNotificationFor (M0.fid sdev) recv
  debug $ show msg
  liftIO $ do
    assertEqual "Response to failed drive should have entries for disk and sdev"
      2 (length msg)
    let [Note _ st1, Note _ st2] = msg
    assertEqual "Initial response to failed drive should be setting TRANSIENT"
      (M0_NC_TRANSIENT, M0_NC_TRANSIENT) (st1, st2)
  debug "failDrive: Transient state set"
  -- The RC should issue a 'ResetAttempt' and should be handled.
  _ <- expect :: Process (Published (HAEvent ResetAttempt))
  -- We should see `ResetAttempt` from SSPL
  let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
          $ nodeCmdString (DriveReset tserial)
  liftIO . assertEqual "drive reset command is issued"  (Just cmd) =<< expectNodeMsg ssplTimeout
  debug "failDrive: OK"

resetComplete :: ProcessId -> StoreChan
              -> ThatWhichWeCallADisk
              -> Process ()
resetComplete rc _ (ADisk sdev m0sdev serial _ _) = let
    enc = Enclosure "enclosure_2"
    tserial = pack serial
    resetCmd = CommandAck Nothing (Just $ DriveReset tserial) AckReplyPassed
  in do
    debug "resetComplete"
    nid <- getSelfNode
    -- Send 'SpielDeviceDetached' to the RC
    forM_ m0sdev $ \sd -> usend rc $ SpielDeviceDetached sd (Right ())
    -- Send 'DriveOK'
    uuid <- liftIO $ nextRandom
    _ <- usend rc $ DriveOK uuid (Node nid) enc sdev
    _ <- promulgateEQ [nid] resetCmd
    let smartTestRequest = ActuatorRequestMessageActuator_request_typeNode_controller
                         $ nodeCmdString (SmartTest tserial)
    debug "resetComplete: waiting smart request."
    liftIO . assertEqual "RC requested smart test." (Just smartTestRequest)
                =<< expectNodeMsg ssplTimeout
    debug "resetComplete: finished"


smartTestComplete :: ProcessId -> ReceivePort NotificationMessage
                  -> AckReply -> ThatWhichWeCallADisk -> Process ()
smartTestComplete rc recv success (ADisk _ msdev serial _ _) = let
    tserial = pack serial
    smartComplete = CommandAck Nothing
                        (Just $ SmartTest tserial)
                        success
    status = case success of
      AckReplyPassed -> M0_NC_ONLINE
      AckReplyFailed -> M0_NC_FAILED
      AckReplyError _ -> M0_NC_FAILED
  in do
    debug $ "smartTestComplete: " ++ show smartComplete
    nid <- getSelfNode
    -- Confirms that the disk powerdown operation has occured.
    _ <- promulgateEQ [nid] smartComplete

    -- If the sdev is there
    forM_ msdev $ \sdev -> do
      -- Send 'SpielDeviceAttached' to the RC
      usend rc $ SpielDeviceAttached sdev (Right ())

      -- Note: this is sensitive to ordering imposed by
      -- 'HA.Services.Mero.RC.Actions.notifyMeroAsync'
      Set [Note _ _, Note fid stat] <- nextNotificationFor (M0.fid sdev) recv
      debug "smartTestComplete: Mero notification received"
      liftIO $ assertEqual
        "Smart test succeeded. Drive fids and status should match."
        (M0.d_fid sdev, status)
        (fid, stat)

--------------------------------------------------------------------------------
-- Actual tests
--------------------------------------------------------------------------------

testDiskFailure :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDiskFailure transport pg = run transport pg interceptor [] test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv _ = do
    prepareSubscriptions rc rmq

    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    resetComplete rc mm sdev
    smartTestComplete rc recv AckReplyPassed sdev

testHitResetLimit :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testHitResetLimit transport pg = run transport pg interceptor [] test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv _ = do
    prepareSubscriptions rc rmq

    sdev <- G.getGraph mm >>= findSDev

    let resetAttemptThreshold = _hv_drive_reset_max_retries defaultHalonVars
    replicateM_ (resetAttemptThreshold + 1) $ do
      debug "============== FAILURE START ================================"
      failDrive recv sdev
      resetComplete rc mm sdev
      smartTestComplete rc recv AckReplyPassed sdev
      debug "============== FAILURE Finish ================================"

    forM_ (aDiskMero sdev) $ \m0sdev -> do
      -- Fail the drive one more time
      let fail_evt = mkSDevFailedMsg m0sdev
      nid <- getSelfNode
      void $ promulgateEQ [nid] fail_evt
      -- Mero should be notified that the drive should be failed.
      Set [Note _ st3, Note _ st4] <- notificationMessage <$> receiveChan recv
      liftIO $ assertEqual "Mero should be notified that the drive should be failed."
        (M0_NC_FAILED, M0_NC_FAILED) (st3, st4)

    return ()

testFailedSMART :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailedSMART transport pg = run transport pg interceptor [] test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv _ = do
    prepareSubscriptions rc rmq

    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    resetComplete rc mm sdev
    smartTestComplete rc recv AckReplyFailed sdev

testSecondReset :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testSecondReset transport pg = run transport pg interceptor [] test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv _ = do
    prepareSubscriptions rc rmq

    sdev <- G.getGraph mm >>= findSDev
    sdev2 <- G.getGraph mm >>= find2SDev

    failDrive recv sdev
    failDrive recv sdev2
    resetComplete rc mm sdev2
    smartTestComplete rc recv AckReplyPassed sdev2
    resetComplete rc mm sdev
    smartTestComplete rc recv AckReplyPassed sdev

-- | SSPL emits EMPTY_None event for one of the drives.
testDriveRemovedBySSPL :: (Typeable g, RGroup g)
                       => Transport -> Proxy g -> IO ()
testDriveRemovedBySSPL transport pg = run transport pg interceptor [] test where
  interceptor _rc _str = return ()
  test (TestArgs _ mm rc) rmq recv _ = do
    prepareSubscriptions rc rmq
    subscribe rc (Proxy :: Proxy DriveRemoved)

    sdev <- G.getGraph mm >>= findSDev

    let enclosure = "enclosure_2"
        host      = pack systemHostname
        devIdx    = 1
        message0 = LBS.toStrict . encode . mkSensorResponse $ mkResponseHPI
                    host (pack enclosure)
                    (pack $ aDiskSN sdev)
                    (fromIntegral devIdx)
                    (pack $ aDiskPath sdev)
                    (pack $ aDiskWWN sdev)
                    False True
        message = LBS.toStrict $ encode $ mkSensorResponse
           $ emptySensorMessage
              { sensorResponseMessageSensor_response_typeDisk_status_drivemanager =
                Just $ mkResponseDriveManager (pack enclosure)
                                              (pack $ aDiskSN sdev)
                                              devIdx "EMPTY" "None"
                                              (pack $ aDiskPath sdev) }
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message0
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message
    Just{} <- expectTimeout ssplTimeout :: Process (Maybe (Published DriveRemoved))
    _ <- receiveTimeout 1000000 []
    debug "Check drive removed"
    True <- checkStorageDeviceRemoved enclosure devIdx <$> G.getGraph mm

    -- XXX: dirty hack: deviceDetach call in mkDetachDisk can't
    -- complete (or even begin) without m0worker. To arrange a mero
    -- worker, we need a better test that also sets up (and tears
    -- down) env than this one here. To temporarily unblock this test,
    -- we "pretend" that the detach went OK by sending the message
    -- that mkDetachDisk would send on successful detach: this is the
    -- message the rule is waiting for.
    forM_ (aDiskMero sdev) $ \sd -> usend rc $ SpielDeviceDetached sd (Right ())

    debug "Check notification"
    forM_ (aDiskMero sdev) $ \m0disk -> do
      -- make sure we're inspecting the right state, ordering can change
      let getCorrectNote (Set ns) = filter (\(Note fid' _) -> M0.fid m0disk == fid') ns
      [Note _ st] <- getCorrectNote <$> nextNotificationFor (M0.fid m0disk) recv
      liftIO $ assertEqual "drive is in transient state" M0_NC_TRANSIENT st

#ifdef USE_MERO
-- | Test that we generate an appropriate pool version in response to
--   failure of a drive, when using 'Dynamic' strategy.
testDynamicPVer :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDynamicPVer transport pg = run transport pg interceptor [] test where
  interceptor _ _ = return ()
  checkPVerExistence rg fids yes = let
      msg = if yes
            then "Pool version should exist"
            else "Pool version should not exist"
      check = if yes then elem else \a -> not . elem a
      [fs] = [ x | Just (p :: M0.Profile) <- [G.connectedTo Cluster Has rg]
                 , x <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem]
                 ]
      pv1 = G.getResourcesOfType rg :: [M0.PVer]
      pvFids = fmap (findRealObjsInPVer rg) pv1
      allFids = findFailableObjs rg fs
      pverFids = allFids `S.difference` fids
    in
      assertMsg msg $ check pverFids pvFids
  test (TestArgs _ mm rc) rmq recv _ = do
    prepareSubscriptions rc rmq
    loadInitialDataMod $ \x -> x {
        id_m0_globals = (id_m0_globals x) { m0_failure_set_gen = Dynamic }
      }

    rg <- G.getGraph mm
    sdev@(ADisk _ (Just m0sdev) _ _ _) <- findSDev rg
    failDrive recv sdev
    -- Should now have a pool version corresponding to single failed drive
    rg1 <- G.getGraph mm
    let Just (disk :: M0.Disk) = G.connectedTo m0sdev M0.IsOnHardware rg1
    checkPVerExistence rg (S.singleton (M0.fid disk)) False
    checkPVerExistence rg1 (S.singleton (M0.fid disk)) True

    sdev2@(ADisk _ (Just m0sdev2) _ _ _)  <- find2SDev rg
    failDrive recv sdev2
    -- Should now have a pool version corresponding to two failed drives
    rg2 <- G.getGraph mm
    let Just (disk2 :: M0.Disk) = G.connectedTo m0sdev2 M0.IsOnHardware rg2
    checkPVerExistence rg1 (S.fromList . fmap M0.fid $ [disk, disk2]) False
    checkPVerExistence rg2 (S.fromList . fmap M0.fid $ [disk, disk2]) True

#endif

-- | Test that a failed drive powers off successfully
testDrivePoweredDown :: (Typeable g, RGroup g)
                      => Transport -> Proxy g -> IO ()
testDrivePoweredDown transport pg = run transport pg interceptor [] test where
  interceptor _rc _str = return ()
  test (TestArgs _ mm rc) rmq recv _ = let
      enc = Enclosure "enclosure_2"
    in do
      prepareSubscriptions rc rmq
      subscribe rc (Proxy :: Proxy (DriveFailed))

      rg <- G.getGraph mm
      nid <- getSelfNode
      eid <- liftIO $ nextRandom
      disk <- findSDev rg
      usend rc $ DriveFailed eid (Node nid) enc (aDiskSD disk)
      -- Need to ack the response to Mero
      forM_ (aDiskMero disk) $ \m0disk ->
        void $ nextNotificationFor (M0.fid m0disk) recv

      debug "Drive failed should be processed"
      _ <- expect :: Process (Published DriveFailed)

      debug "SSPL should receive a command to power off the drive"
      do
        msg <- expectNodeMsg ssplTimeout
        debug $ "sspl_msg(poweroff): " ++ show msg
        let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                  $ nodeCmdString (DrivePowerdown . pack $ aDiskSN disk)
        liftIO $ assertEqual "drive powerdown command is issued"  (Just cmd) msg

-- | Test that we respond correctly to a notification that a RAID device
--   has failed.
testMetadataDriveFailed :: (Typeable g, RGroup g)
                        => Transport -> Proxy g -> IO ()
testMetadataDriveFailed transport pg = run transport pg interceptor [] test where
  interceptor _rc _str = return ()
  test (TestArgs _ mm rc) rmq recv _ = let
      host = pack systemHostname
      raidDevice = "/dev/raid"
      raidData = mkResponseRaidData host raidDevice
                                    [ (("/dev/mddisk1", "mdserial1"), True) -- disk1 ok
                                    , (("/dev/mddisk2", "mdserial2"), False) -- disk2 failed
                                    ]
      message = LBS.toStrict $ encode
                               $ mkSensorResponse
                               $ emptySensorMessage {
                                  sensorResponseMessageSensor_response_typeRaid_data = Just raidData
                                }
    in do
      prepareSubscriptions rc rmq
      usend rmq $ MQBind "sspl_iem" "sspl_iem" "sspl_ll"
      usend rmq . MQSubscribe "sspl_iem" =<< getSelfPid

      subscribe rc (Proxy :: Proxy (HAEvent (NodeId, SensorResponseMessageSensor_response_typeRaid_data)))

      usend rmq $ MQPublish "sspl_halon" "sspl_ll" message
      nid <- getSelfNode

      debug "RAID message published"
      -- Expect the message to be processed by RC
      _ <- expect :: Process (Published (HAEvent (NodeId, SensorResponseMessageSensor_response_typeRaid_data)))

      do
        Just (uid, msg) <- expectNodeMsgUid ssplTimeout
        -- We should see a message to SSPL to remove the drive
        let nc = NodeRaidCmd raidDevice (RaidRemove "/dev/mddisk2")
            cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                  $ nodeCmdString nc
        liftIO $ assertEqual "drive removal command is issued" cmd msg
        void . promulgateEQ [nid] $ CommandAck uid (Just nc) AckReplyPassed

      -- The RC should issue a 'ResetAttempt' and should be handled.
      debug "RAID removal for drive received at SSPL"
      _ <- expect :: Process (Published (HAEvent ResetAttempt))

      rg <- G.getGraph mm
      -- Look up the storage device by path
      let [sd]  = [ d |  d <- G.connectedTo (Host systemHostname) Has rg
                      , di <- G.connectedTo d Has rg
                      , di == DIPath "/dev/mddisk2"
                      ]

      let disk2 = ADisk {
          aDiskSD = sd
        , aDiskMero = Nothing
        , aDiskSN = "mdserial2"
        , aDiskPath = "/dev/mddisk2"
        , aDiskWWN = error "WWN not initialised"
      }

      debug "ResetAttempt message published"
      -- We should see `ResetAttempt` from SSPL
      do
        msg <- expectNodeMsg ssplTimeout
        debug $ "sspl_msg(reset): " ++ show msg
        let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                  $ nodeCmdString (DriveReset "mdserial2")
        liftIO $ assertEqual "drive reset command is issued"  (Just cmd) msg

      debug "Reset command received at SSPL"
      resetComplete rc mm disk2
      smartTestComplete rc recv AckReplyPassed disk2

      do
        msg <- expectNodeMsg ssplTimeout
        debug $ "sspl_msg(raid_add): " ++ show msg
        let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                  $ nodeCmdString (NodeRaidCmd raidDevice (RaidAdd "/dev/mddisk2"))
        liftIO $ assertEqual "Drive is added back to raid array" (Just cmd) msg

      debug "Raid_data message processed by RC"

testGreeting :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testGreeting transport pg = run transport pg interceptor [] test where
  interceptor _rc _str = return ()
  test (TestArgs _ _ rc) rmq _ _ = do
    prepareSubscriptions rc rmq

    _ <- promulgate MarkDriveFailed
    Nothing <- expectTimeout ssplTimeout :: Process (Maybe (Published (HAEvent MarkDriveFailed)))
    let
      message = LBS.toStrict $ encode
                               $ mkActuatorResponse
                               $ emptyActuatorMessage {
                                  actuatorResponseMessageActuator_response_typeThread_controller = Just $
                                    ActuatorResponseMessageActuator_response_typeThread_controller
                                      "ThreadController"
                                      "SSPL-LL service has started successfully"
                                 }
      -- led  = ActuatorRequestMessageActuator_request_typeNode_controller
      --     $ nodeCmdString (DriveLed "serial24" FaultOn)
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message
    mmsg1 <- expectNodeMsg ssplTimeout
    case mmsg1 of
      Just _s  -> return () -- XXX: uids are not deterministic
      Nothing -> liftIO $ assertFailure "node cmd was not received"
    mmsg2 <- expectLoggingMsg ssplTimeout
    case mmsg2 of
      Left s  -> liftIO $ assertFailure $ "wrong message received" ++ s
      Right _  -> return ()

type RaidMsg = (NodeId, SensorResponseMessageSensor_response_typeRaid_data)

testExpanderResetRAIDReassemble :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testExpanderResetRAIDReassemble transport pg = run transport pg interceptor [] test where
  interceptor _rc _str = return ()
  test (TestArgs _ mm rc) rmq recv recc = do
    prepareSubscriptions rc rmq
    subscribe rc (Proxy :: Proxy (HAEvent ExpanderReset))
    subscribe rc (Proxy :: Proxy (HAEvent RaidMsg))

    let host = pack systemHostname
        raidDevice = "/dev/raid"
        raidData = mkResponseRaidData host raidDevice
                                        [ (("/dev/mddisk1", "mdserial1"), True) -- disk1 ok
                                        , (("/dev/mddisk2", "mdserial2"), True) -- disk2 failed
                                        ]
        raidMsg = LBS.toStrict . encode
              $ mkSensorResponse $ emptySensorMessage {
                  sensorResponseMessageSensor_response_typeRaid_data = Just raidData
              }
        erm = LBS.toStrict . encode
              $ mkSensorResponse $ emptySensorMessage {
                  sensorResponseMessageSensor_response_typeExpander_reset =
                    Just Aeson.Null
                }

    -- Before we can do anything, we need to establish a fake RAID device.
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" raidMsg
    _ <- expect :: Process (Published (HAEvent RaidMsg))
    debug "RAID devices established"

    nid <- getSelfNode

    rg <- G.getGraph mm
    let encs = [ enc | rack <- G.connectedTo Cluster Has rg :: [Rack]
                     , enc <- G.connectedTo rack Has rg]

    debug $ "Enclosures: " ++ show encs
    let [enc] = encs
        (Just m0enc) = encToM0Enc enc rg

    debug $ "(enc, m0enc): " ++ show (enc, m0enc)

    -- First, we sent expander reset message for an enclosure.
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" erm

    -- Should get propogated to the RC
    _ <- expect :: Process (Published (HAEvent ExpanderReset))
    debug "ExpanderReset rule fired"

    -- Should expect notification from Mero that the enclosure is transient
    do
      Set notes <- nextNotificationFor (M0.fid m0enc) recv
      debug $ "Enc-transient-notes: " ++ show notes
      liftIO $ assertBool "enclosure is in transient state" $
               (Note (M0.fid m0enc) M0_NC_TRANSIENT) `elem` notes

    -- Should also expect a message to SSPL asking it to disable swap
    _ <- do
      Just (uid, msg) <- expectNodeMsgUid ssplTimeout
      debug $ "sspl_msg(disable_swap): " ++ show msg
      let nc = SwapEnable False
          cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                $ nodeCmdString nc
      liftIO $ assertEqual "Swap is disabled" cmd msg
      -- Reply with a command acknowledgement
      void . promulgateEQ [nid] $ CommandAck uid (Just nc) AckReplyPassed

    -- Mero services should be stopped
    _ <- do
      StopProcesses pcs <- receiveChan recc
      liftIO $ assertEqual "One process on node" 1 $ length pcs
      -- Reply with successful stoppage
      let [(_, fid)] = pcs
      void . promulgateEQ [nid] $ ProcessControlResultStopMsg nid [Right fid]

    debug "Mero process stop result sent"
    -- We will not see 'OFFLINE' since the process on this node is offline

    -- Should see unmount message
    _ <- do
      Just (uid, msg) <- expectNodeMsgUid ssplTimeout
      debug $ "sspl_msg(unmount): " ++ show msg
      let nc = (Unmount "/var/mero")
          cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                $ nodeCmdString nc
      liftIO $ assertEqual "/var/mero is unmounted" cmd msg
      -- Reply with a command acknowledgement
      void . promulgateEQ [nid] $ CommandAck uid (Just nc) AckReplyPassed

    -- Should see 'stop RAID' message
    _ <- do
      Just (uid, msg) <- expectNodeMsgUid ssplTimeout
      debug $ "sspl_msg(stop_raid): " ++ show msg
      let nc = NodeRaidCmd raidDevice RaidStop
          cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                $ nodeCmdString nc
      liftIO $ assertEqual "RAID is stopped" cmd msg
      -- Reply with a command acknowledgement
      void . promulgateEQ [nid] $ CommandAck uid (Just nc) AckReplyPassed

    -- Should see 'reassemble RAID' message
    _ <- do
      Just (uid, msg) <- expectNodeMsgUid ssplTimeout
      debug $ "sspl_msg(assemble_raid): " ++ show msg
      let nc = NodeRaidCmd "--scan" (RaidAssemble [])
          cmd = ActuatorRequestMessageActuator_request_typeNode_controller
                $ nodeCmdString nc
      liftIO $ assertEqual "RAID is assembling" cmd msg
      -- Reply with a command acknowledgement
      void . promulgateEQ [nid] $ CommandAck uid (Just nc) AckReplyPassed

    -- Mero services should be restarted
    do
      debug "configure process"
      mconf <- receiveChan recc
      case mconf of
        ConfigureProcess _ pc _ -> do
          let p = case pc of
                ProcessConfigLocal p' _ -> p'
                ProcessConfigRemote p' -> p'
          _ <- promulgateEQ [nid] $ ProcessControlResultConfigureMsg nid (Right p)
          return ()
        s -> liftIO $ assertFailure $ "Expected configure request, but received " ++ show s

      debug "start process"
      mstart <- receiveChan recc
      case mstart of
        StartProcess _ p -> do
          -- Reply with successful stoppage
          let fid = M0.fid p
          _ <- promulgateEQ [nid] $ ProcessControlResultMsg nid (Right (p, Just 123))
          -- Also send ONLINE for the process
          let pe = ProcessEvent TAG_M0_CONF_HA_PROCESS_STARTED
                                TAG_M0_CONF_HA_PROCESS_M0D
                                123
              meta = HAMsgMeta fid fid fid 0
          _ <- promulgateEQ [nid] $ HAMsg pe meta
          return ()
        s ->  liftIO $ assertFailure $ "Expected (re)start request, but received " ++ show s

    debug "Mero process start result sent"

    -- Should expect notification from Mero that the enclosure is online
    do
      Set notes <- nextNotificationFor (M0.fid m0enc) recv
      debug $ "Enc-online-notes: " ++ show notes
      liftIO $ assertBool "enclosure is in online state" $
               (Note (M0.fid m0enc) M0_NC_ONLINE) `elem` notes

    return ()
