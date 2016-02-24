{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module HA.Castor.Story.Tests (mkTests
#ifdef USE_MERO
 , testDynamicPVer
#endif
 ) where

import HA.EventQueue.Producer
import HA.EventQueue.Types
#ifdef USE_MERO
import HA.RecoveryCoordinator.Actions.Mero.Failure.Dynamic
   ( findRealObjsInPVer
   , findFailableObjs
   )
#endif
import HA.RecoveryCoordinator.Events.Drive
import HA.RecoveryCoordinator.Rules.Castor
import qualified HA.ResourceGraph as G
import HA.NodeUp (nodeUp)
import Mero.Notification
import Mero.Notification.HAState
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
import HA.Service
import HA.Services.Mero
import HA.Services.SSPL
import HA.Services.SSPL.Rabbit
import HA.Services.SSPL.LL.Resources
import HA.RecoveryCoordinator.Mero

import RemoteTables (remoteTable)

import SSPL.Bindings

import Control.Monad (when, replicateM_, void)
import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Node
import Control.Exception as E hiding (assert)

import Data.Aeson (decode, encode)
import Data.Binary (Binary)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Hashable (Hashable)
import qualified Data.Set as S
import Data.Typeable
import Data.Text (append, pack)
import Data.Text.Encoding (decodeUtf8)
import Data.Maybe (isNothing)
import Data.Defaultable
import qualified Data.UUID as UUID

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
debug = say

myRemoteTable :: RemoteTable
myRemoteTable = TestRunner.__remoteTableDecl remoteTable

newtype MockM0 = MockM0 DeclareMeroChannel
  deriving (Binary, Generic, Hashable, Typeable)

mockMeroConf :: MeroConf
mockMeroConf = MeroConf "" "" (MeroKernelConf UUID.nil)

data MarkDriveFailed = MarkDriveFailed deriving (Generic, Typeable)
instance Binary MarkDriveFailed

newMeroChannel :: ProcessId -> Process (ReceivePort NotificationMessage, MockM0)
newMeroChannel pid = do
  (sd, recv) <- newChan
  (blah, _) <- newChan
  let sdChan   = TypedChannel sd
      connChan = TypedChannel blah
      notfication = MockM0
              $ DeclareMeroChannel (ServiceProcess pid) sdChan connChan
  return (recv, notfication)

testRules :: Definitions LoopState ()
testRules = do
  defineSimple "register-mock-service" $
    \(HAEvent eid (MockM0 dc@(DeclareMeroChannel sp _ _)) _) -> do
      nid <- liftProcess $ getSelfNode
      registerServiceProcess (Node nid) m0d mockMeroConf sp
      void . liftProcess $ promulgateEQ [nid] dc
      messageProcessed eid
  defineSimple "mark-disk-failed" $ \(HAEvent eid MarkDriveFailed _) -> do
      rg <- getLocalGraph
      case G.getResourcesOfType rg of
        (sd:_) -> updateDriveStatus sd "HALON-FAILED" "MERO-Timeout"
        [] -> return ()
      messageProcessed eid

mkTests :: IO (Transport -> [TestTree])
mkTests = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (_::AMQPException) -> return $ \_->
      [testSuccess "Drive failure tests disabled (can't connect to rabbitMQ)"  $ return ()]
    Right x -> do
      closeConnection x
      return $ \transport ->
        [ testSuccess "Drive failure, successful reset and smart test success" $
          testDiskFailure transport
        , testSuccess "Drive failure, repeated attempts to reset, hitting reset limit" $
          testHitResetLimit transport
        , testSuccess "Drive failure, successful reset, failed smart test" $
          testFailedSMART transport
        , testSuccess "Drive failure, second drive fails whilst handling to reset attempt" $
          testSecondReset transport
--        , testSuccess "No response from powerdown" $
--          testPowerdownNoResponse transport
--        , testSuccess "No response from powerup" $
--          testPowerupNoResponse transport
--        , testSuccess "No response from SMART test" $
--          testSMARTNoResponse transport
        , testSuccess "Drive failure removal reported by SSPL" $
          testDriveRemovedBySSPL transport
        , testSuccess "Metadata drive failure reported by IEM" $
          testMetadataDriveFailed transport
        , testSuccess "Halon sends list of failed drives at SSPL start" $
          testGreeting transport
        ]

run :: Transport
    -> (ProcessId -> String -> Process ()) -- interceptor callback
    -> (    TestArgs
         -> ProcessId
         -> ReceivePort NotificationMessage
         -> Process ()
       ) -- actual test
    -> Assertion
run transport interceptor test =
  runTest 2 20 15000000 transport myRemoteTable $ \[n] -> do
    self <- getSelfPid
    nid <- getSelfNode
    withTrackingStation [testRules] $ \ta -> do
      nodeUp ([nid], 1000000)
      registerInterceptor $ \string ->
        case string of
          str@"Starting service sspl"   -> usend self str
          x -> interceptor self x

      startSSPLService (ta_rc ta)
      debug "Started SSPL service"
      meroRP <- startMeroServiceMock (ta_rc ta)
      debug "Started Mero mock service"
      rmq <- spawnMockRabbitMQ self
      debug "Started mock RabbitMQ service."
      -- Run the test
      debug "About to run the test"

      test ta rmq meroRP
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
      subscribe rc (Proxy :: Proxy (HAEvent DeclareMeroChannel))
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

      return ()

    startMeroServiceMock :: ProcessId -> Process (ReceivePort NotificationMessage)
    startMeroServiceMock rc = do
      subscribe rc (Proxy :: Proxy (HAEvent DeclareChannels))
      nid <- getSelfNode
      pid <- getSelfPid
      (recv, channel) <- newMeroChannel pid
      _ <- promulgateEQ [nid] channel
      _ <- expect :: Process (Published (HAEvent DeclareChannels))
      return recv

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

findSDev :: G.Graph -> Process (M0.SDev,String)
findSDev rg =
  let dvs = [ (sdev, serial) | sdev <- G.getResourcesOfType rg :: [M0.SDev]
                             , disk <- G.connectedTo sdev M0.IsOnHardware rg :: [M0.Disk]
                             , storage <- G.connectedTo disk M0.At rg :: [StorageDevice]
                             , DISerialNumber serial <- G.connectedTo storage Has rg
                             ]
  in case dvs of
    dv:_ -> return dv
    _    -> do liftIO $ assertFailure "Can't find a M0.SDev or it's serial number"
               undefined

find2SDev :: G.Graph -> Process (M0.SDev, String)
find2SDev rg =
  case G.getResourcesOfType rg of
    _:sdev:_ -> case [ (sdev, serial) | DISerialNumber serial <- devDI sdev rg ] of
                  sd:_ -> return sd
                  _  -> do liftIO $ assertFailure "Can't find serial number."
                           undefined
    _        -> do liftIO $ assertFailure "Can't find more than 2 SDevs"
                   undefined

devAttrs :: M0.SDev -> G.Graph -> [StorageDeviceAttr]
devAttrs sdev rg =
  [ attr | dev  <- G.connectedTo sdev M0.IsOnHardware rg :: [M0.Disk]
         , sd   <- G.connectedTo dev M0.At rg :: [StorageDevice]
         , attr <- G.connectedTo sd Has rg :: [StorageDeviceAttr]
         ]

devDI :: M0.SDev -> G.Graph -> [DeviceIdentifier]
devDI sdev rg =
  [ attr | dev  <- G.connectedTo sdev M0.IsOnHardware rg :: [M0.Disk]
         , sd   <- G.connectedTo dev M0.At rg :: [StorageDevice]
         , attr <- G.connectedTo sd Has rg :: [DeviceIdentifier]
         ]



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
isPowered SDPowered = True
isPowered _         = False

expectNodeMsg :: Int -> Process (Maybe ActuatorRequestMessageActuator_request_typeNode_controller)
expectNodeMsg = expectActuatorMsg
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


expectActuatorMsg :: (ActuatorRequest -> Maybe b) -> Int -> Process (Maybe b)
expectActuatorMsg f t = do
  expectTimeout t >>= \case
    Just (MQMessage _ msg) -> return $ f =<< (decode . LBS.fromStrict $ msg)
    Nothing -> do liftIO $ assertFailure "No message delivered to SSPL."
                  undefined

expectActuatorMsg' :: (ActuatorRequest -> Maybe b) -> Int -> Process (Either String b)
expectActuatorMsg' f t = do
  expectTimeout t >>= \case
    Just (MQMessage _ msg) -> return $ case f =<< (decode . LBS.fromStrict $ msg) of
         Nothing -> Left (BS8.unpack msg)
         Just x  -> Right x
    Nothing -> do liftIO $ assertFailure "No message delivered to SSPL."
                  undefined

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

failDrive :: ReceivePort NotificationMessage -> (M0.SDev,String) -> Process ()
failDrive recv (sdev, serial) = let
    fail_evt = Set [Note (M0.d_fid sdev) M0_NC_FAILED]
    tserial = pack serial
  in do
    debug "failDrive"
    nid <- getSelfNode
    -- We a drive failure note to the RC.
    _ <- promulgateEQ [nid] fail_evt
    -- Mero should be notified that the drive should be transient.
    Set [Note _ M0_NC_TRANSIENT, Note _ M0_NC_TRANSIENT] <- notificationMessage <$> receiveChan recv
    debug "failDrive: Transient state set"
    -- The RC should issue a 'ResetAttempt' and should be handled.
    _ <- expect :: Process (Published (HAEvent ResetAttempt))
    -- We should see `ResetAttempt` from SSPL
    let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
            $ nodeCmdString (DriveReset tserial)
    liftIO . assertEqual "drive reset command is issued"  (Just cmd) =<< expectNodeMsg 1000000
    debug "failDrive: OK"

resetComplete :: StoreChan -> (M0.SDev, String) -> Process ()
resetComplete mm (sdev, serial) = let
    tserial = pack serial
    resetCmd = CommandAck Nothing (Just $ DriveReset tserial) AckReplyPassed
  in do
    debug "resetComplete"
    nid <- getSelfNode
    rg <- G.getGraph mm
    liftIO . assertBool "false_dev should we power off"
           . not . any isPowered $ devAttrs sdev rg
    _ <- promulgateEQ [nid] resetCmd
    let smartTestRequest = ActuatorRequestMessageActuator_request_typeNode_controller
                         $ nodeCmdString (SmartTest tserial)
    debug "resetComplete: waiting smart request."
    liftIO . assertEqual "RC requested smart test." (Just smartTestRequest)
                =<< expectNodeMsg 1000000
    debug "resetComplete: finished"


smartTestComplete :: ReceivePort NotificationMessage -> AckReply -> (M0.SDev,String) -> Process ()
smartTestComplete recv success (sdev,serial) = let
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
    Set [Note fid stat, Note _ _] <- notificationMessage  <$> receiveChan recv
    debug "smartTestComplete: Mero notification received"
    liftIO $ assertEqual
      "Smart test succeeded. Drive fids and status should match."
      (M0.d_fid sdev, status)
      (fid, stat)

--------------------------------------------------------------------------------
-- Actual tests
--------------------------------------------------------------------------------

testDiskFailure :: Transport -> IO ()
testDiskFailure transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData

    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    resetComplete mm sdev
    smartTestComplete recv AckReplyPassed sdev

testHitResetLimit :: Transport -> IO ()
testHitResetLimit transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData

    sdev <- G.getGraph mm >>= findSDev

    replicateM_ (resetAttemptThreshold + 1) $ do
      failDrive recv sdev
      resetComplete mm sdev
      smartTestComplete recv AckReplyPassed sdev

    -- Fail the drive one more time
    let fail_evt = Set [Note (M0.d_fid $ fst sdev) M0_NC_FAILED]
    nid <- getSelfNode
    void $ promulgateEQ [nid] fail_evt
    -- Mero should be notified that the drive should be failed.
    Set [Note _ M0_NC_FAILED, Note _ M0_NC_FAILED] <- notificationMessage <$> receiveChan recv

    return ()

testFailedSMART :: Transport -> IO ()
testFailedSMART transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData

    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    resetComplete mm sdev
    smartTestComplete recv AckReplyFailed sdev

testSecondReset :: Transport -> IO ()
testSecondReset transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData

    sdev <- G.getGraph mm >>= findSDev
    sdev2 <- G.getGraph mm >>= find2SDev

    failDrive recv sdev
    failDrive recv sdev2
    resetComplete mm sdev2
    smartTestComplete recv AckReplyPassed sdev2
    resetComplete mm sdev
    smartTestComplete recv AckReplyPassed sdev

{-
testPowerdownNoResponse :: Transport -> IO ()
testPowerdownNoResponse transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData

    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    -- No response to powerdown command, should try again
    liftIO $ threadDelay 1000001
    let sdev_path = pack $ M0.d_path sdev
    msg <- expectNodeMsg 1000000
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (DrivePowerdown sdev_path))
                    )
    -- This time, we get a response
    powerdownComplete mm sdev
    poweronComplete mm sdev
    smartTestComplete recv AckReplyPassed sdev


testPowerupNoResponse :: Transport -> IO ()
testPowerupNoResponse transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData

    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    powerdownComplete mm sdev
    -- No response to poweron command, should try again
    liftIO $ threadDelay 1000001
    let sdev_path = pack $ M0.d_path sdev
    msg <- expectNodeMsg 1000000
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (DrivePoweron sdev_path))
                    )
    -- This time, we get a response
    poweronComplete mm sdev
    smartTestComplete recv AckReplyPassed sdev

testSMARTNoResponse :: Transport -> IO ()
testSMARTNoResponse transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData
    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    powerdownComplete mm sdev
    poweronComplete mm sdev
    -- No response to SMART test, should try power cycle again
    liftIO $ threadDelay 1000001
    let sdev_path = pack $ M0.d_path sdev
    msg <- expectNodeMsg 1000000
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (DrivePowerdown sdev_path))
                    )
    powerdownComplete mm sdev
    poweronComplete mm sdev
    smartTestComplete recv AckReplyPassed sdev
    return ()
-}

-- | SSPL emits EMPTY_None event for one of the drives.
testDriveRemovedBySSPL :: Transport -> IO ()
testDriveRemovedBySSPL transport = run transport interceptor test where
  interceptor _rc _str = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData
    subscribe rc (Proxy :: Proxy DriveRemoved)
    let enclosure = "enclosure_2"
        host      = pack systemHostname
        devIdx    = 1
        message0 = LBS.toStrict $ encode
                                $ mkSensorResponse
                                $ mkResponseHPI host (pack enclosure) "serial21" (fromIntegral devIdx) "/dev/loop21" "wwn21"
        message = LBS.toStrict $ encode $ mkSensorResponse
           $ emptySensorMessage
              { sensorResponseMessageSensor_response_typeDisk_status_drivemanager =
                Just $ mkResponseDriveManager (pack enclosure) "serial21" devIdx "EMPTY" "None" "/path" }
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message0
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message
    Just{} <- expectTimeout 1000000 :: Process (Maybe (Published DriveRemoved))
    _ <- receiveTimeout 1000000 []
    debug "Check drive removed"
    True <- checkStorageDeviceRemoved enclosure devIdx <$> G.getGraph mm
    debug "Check notification"
    Set [Note _ st, Note _ _] <- notificationMessage <$> receiveChan recv
    liftIO $ assertEqual "drive is in transient state" M0_NC_TRANSIENT st

#ifdef USE_MERO
-- | Test that we generate an appropriate pool version in response to
--   failure of a drive, when using 'Dynamic' strategy.
testDynamicPVer :: Transport -> IO ()
testDynamicPVer transport = run transport interceptor test where
  interceptor _ _ = return ()
  checkPVerExistence rg fids yes = let
      msg = if yes
            then "Pool version should exist"
            else "Pool version should not exist"
      check = if yes then elem else \a -> not . elem a
      [fs] = [ x | p <- G.connectedTo Cluster Has rg :: [M0.Profile]
                 , x <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem]
                 ]
      pv1 = G.getResourcesOfType rg :: [M0.PVer]
      pvFids = fmap (findRealObjsInPVer rg) pv1
      allFids = findFailableObjs rg fs
      pverFids = allFids `S.difference` fids
    in
      assertMsg msg $ check pverFids pvFids
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialDataMod $ \x -> x {
        id_m0_globals = (id_m0_globals x) { m0_failure_set_gen = Dynamic }
      }

    rg <- G.getGraph mm
    sdev <- findSDev rg
    failDrive recv sdev
    -- Should now have a pool version corresponding to single failed drive
    rg1 <- G.getGraph mm
    let [disk] = G.connectedTo (fst sdev) M0.IsOnHardware rg1 :: [M0.Disk]
    checkPVerExistence rg (S.singleton (M0.fid disk)) False
    checkPVerExistence rg1 (S.singleton (M0.fid disk)) True

    sdev2 <- find2SDev rg
    failDrive recv sdev2
    -- Should now have a pool version corresponding to two failed drives
    rg2 <- G.getGraph mm
    let [disk2] = G.connectedTo (fst sdev2) M0.IsOnHardware rg2 :: [M0.Disk]
    checkPVerExistence rg1 (S.fromList . fmap M0.fid $ [disk, disk2]) False
    checkPVerExistence rg2 (S.fromList . fmap M0.fid $ [disk, disk2]) True
#endif

-- | Test that we respond correctly to a notification that a RAID device
--   has failed by sending an IEM.
testMetadataDriveFailed :: Transport -> IO ()
testMetadataDriveFailed transport = run transport interceptor test where
  interceptor _rc _str = return ()
  test (TestArgs _ _ rc) rmq _ = do
    usend rmq $ MQBind "halon_sspl" "halon_sspl" "sspl_ll"
    usend rmq $ MQBind "sspl_iem" "sspl_iem" "sspl_ll"
    usend rmq . MQSubscribe "sspl_iem" =<< getSelfPid
    subscribe rc (Proxy :: Proxy (HAEvent (NodeId, SensorResponseMessageSensor_response_typeRaid_data)))

    let
      host = pack systemHostname
      raidData = mkResponseRaidData host "U_"
      message = LBS.toStrict $ encode
                               $ mkSensorResponse
                               $ emptySensorMessage {
                                  sensorResponseMessageSensor_response_typeRaid_data = Just raidData
                                }
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message
    Just{} <- expectTimeout 1000000 :: Process (Maybe (Published (HAEvent (NodeId, SensorResponseMessageSensor_response_typeRaid_data))))
    debug "Raid_data message processed by RC"
    mx <- receiveTimeout 1000000
            [ matchIf (\(MQMessage _ msg) ->
                         "Metadata drive failure on host " `append` host == decodeUtf8 msg)
                      (const $ return ())]
    when (isNothing mx) $ error "No message delivered to SSPL."

testGreeting :: Transport -> IO ()
testGreeting transport = run transport interceptor test where
  interceptor _rc _str = return ()
  test (TestArgs _ _ rc) rmq _ = do
    prepareSubscriptions rc rmq
    loadInitialData

    _ <- promulgate MarkDriveFailed
    Nothing <- expectTimeout 1000000 :: Process (Maybe (Published (HAEvent MarkDriveFailed)))
    let
      message = LBS.toStrict $ encode
                               $ mkActuatorResponse
                               $ emptyActuatorMessage {
                                  actuatorResponseMessageActuator_response_typeThread_controller = Just $
                                    ActuatorResponseMessageActuator_response_typeThread_controller 
                                      "ThreadController"
                                      "SSPL-LL service has started successfully"
                                }
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message
    mmsg <- expectLoggingMsg 1000000
    case mmsg of
      Left s  -> liftIO $ assertFailure $ "wrong message received" ++ s
      Right _  -> return ()

