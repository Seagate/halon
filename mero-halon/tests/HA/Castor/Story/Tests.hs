{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TemplateHaskell   #-}
module HA.Castor.Story.Tests (mkTests) where

import HA.EventQueue.Producer
import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Service
  ( registerServiceProcess )
import HA.RecoveryCoordinator.Events.Drive
import HA.RecoveryCoordinator.Mero (LoopState)
import HA.RecoveryCoordinator.Rules.Castor
import qualified HA.ResourceGraph as G
import HA.Castor.Tests (initialDataAddr)
import HA.NodeUp (nodeUp)
import Mero.Notification
import Mero.Notification.HAState
import HA.Resources
import HA.Resources.Castor.Initial (InitialData)
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.Service
import HA.Services.Mero
import HA.Services.SSPL
import HA.Services.SSPL.Rabbit
import HA.Services.SSPL.LL.Resources

import RemoteTables (remoteTable)

import SSPL.Bindings

import Control.Concurrent (threadDelay)
import Control.Monad (join, when, replicateM_, void)
import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Node
import Control.Exception as E hiding (assert)

import Data.Aeson (decode, encode)
import Data.Binary (Binary)
import qualified Data.ByteString.Lazy as LBS
import Data.Hashable (Hashable)
import Data.Typeable
import Data.Text (pack)
import Data.Defaultable
import qualified Data.List as List

import GHC.Generics (Generic)

import Network.AMQP
import Network.CEP
import Network.Transport

import Test.Framework
import Test.Tasty.HUnit (Assertion, assertEqual)
import TestRunner
import Helper.SSPL

debug :: String -> Process ()
debug = liftIO . appendFile "/tmp/halon.debug" . (++ "\n")

myRemoteTable :: RemoteTable
myRemoteTable = TestRunner.__remoteTableDecl remoteTable

newtype MockM0 = MockM0 DeclareMeroChannel
  deriving (Binary, Generic, Hashable, Typeable)

mockMeroConf :: MeroConf
mockMeroConf = MeroConf "" ""

newMeroChannel :: ProcessId -> Process (ReceivePort Set, MockM0)
newMeroChannel pid = do
  (sd, recv) <- newChan
  let sdChan   = TypedChannel sd
      notfication = MockM0
              $ DeclareMeroChannel (ServiceProcess pid) sdChan
  return (recv, notfication)

testRules :: Definitions LoopState ()
testRules = do
  defineSimple "register-mock-service" $
    \(HAEvent _ (MockM0 dc@(DeclareMeroChannel sp _)) _) -> do
      nid <- liftProcess $ getSelfNode
      registerServiceProcess (Node nid) m0d mockMeroConf sp
      void . liftProcess $ promulgateEQ [nid] dc

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
        , testSuccess "No response from powerdown" $
          testPowerdownNoResponse transport
        , testSuccess "No response from powerup" $
          testPowerupNoResponse transport
        , testSuccess "No response from SMART test" $
          testSMARTNoResponse transport
        , testSuccess "Drive failure removal reported by SSPL" $
          testDriveRemovedBySSPL transport
        ]

run :: Transport
    -> (ProcessId -> String -> Process ()) -- interceptor callback
    -> (    TestArgs
         -> ProcessId
         -> ReceivePort Set
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

      -- Tear down the test
      _ <- promulgateEQ [localNodeId n] $ encodeP $
            ServiceStopRequest (Node $ localNodeId n) sspl
      _ <- receiveTimeout 1000000 []
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

    startMeroServiceMock :: ProcessId -> Process (ReceivePort Set)
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

findSDev :: G.Graph -> Process M0.SDev
findSDev rg =
  case G.getResourcesOfType rg of
    sdev:_ -> return sdev
    _      -> fail "Can't find a M0.SDev"

find2SDev :: G.Graph -> Process M0.SDev
find2SDev rg =
  case G.getResourcesOfType rg of
    _:sdev:_ -> return sdev
    _        -> fail "Can't find more than 2 SDevs"

devAttrs :: M0.SDev -> G.Graph -> [StorageDeviceAttr]
devAttrs sdev rg =
  [ attr | dev  <- G.connectedTo sdev M0.IsOnHardware rg :: [M0.Disk]
         , sd   <- G.connectedTo dev M0.At rg :: [StorageDevice]
         , attr <- G.connectedTo sd Has rg :: [StorageDeviceAttr]
         ]

-- | Check if specified device have RemovedAt attribute.
checkStorageDeviceRemoved :: String -> Int -> G.Graph -> Bool
checkStorageDeviceRemoved enc idx rg = not . Prelude.null $
  [ () | host <- G.connectedTo (Enclosure enc) Has rg :: [Host]
       , dev  <- G.connectedTo host Has rg :: [StorageDevice]
       , any (==(DIIndexInEnclosure idx)) 
             (G.connectedTo dev Has rg :: [DeviceIdentifier])
       , any (==SDRemovedAt) 
             (G.connectedTo dev Has rg :: [StorageDeviceAttr])
       ]

isPowered :: StorageDeviceAttr -> Bool
isPowered SDPowered = True
isPowered _         = False

expectNodeMsg :: Int -> Process (Maybe ActuatorRequestMessageActuator_request_typeNode_controller)
expectNodeMsg t = do
  expectTimeout t >>= \case
    Just (MQMessage _ msg) ->
      return . join
        $ actuatorRequestMessageActuator_request_typeNode_controller
        . actuatorRequestMessageActuator_request_type
        . actuatorRequestMessage
        <$> (decode . LBS.fromStrict $ msg)
    Nothing -> error "No message delivered to SSPL."

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
    init_msg = initialDataAddr "10.0.2.15" "10.0.2.15" 8
  in do
    nid <- getSelfNode
    -- We populate the graph with confc context.
    _ <- promulgateEQ [nid] init_msg
    _ <- expect :: Process (Published (HAEvent InitialData))
    return ()

failDrive :: ReceivePort Set -> M0.SDev -> Process ()
failDrive recv sdev = let
    fail_evt = Set [Note (M0.d_fid sdev) M0_NC_FAILED]
    sdev_path = pack $ M0.d_path sdev
  in do
    debug "failDrive"
    nid <- getSelfNode
    -- We a drive failure note to the RC.
    _ <- promulgateEQ [nid] fail_evt
    -- Mero should be notified that the drive should be transient.
    Set [Note _ M0_NC_TRANSIENT] <- receiveChan recv
    debug "failDrive: Transient state set"
    -- The RC should issue a 'ResetAttempt' and should be handled.
    _ <- expect :: Process (Published (HAEvent ResetAttempt))
    -- We should see `ResetAttempt` from SSPL
    msg <- expectNodeMsg 1000000
    debug $ "failDrive: Msg: " ++ show msg
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (DrivePowerdown sdev_path))
                    )

powerdownComplete :: ProcessId -> M0.SDev -> Process ()
powerdownComplete mm sdev = let
    sdev_path = pack $ M0.d_path sdev
    downComplete = CommandAck Nothing
                                (Just $ DrivePowerdown sdev_path)
                                AckReplyPassed
  in do
    debug "powerdownComplete"
    nid <- getSelfNode
    -- Confirms that the disk powerdown operation has occured.
    _ <- promulgateEQ [nid] downComplete
    _ <- expect :: Process (Published CommandAck)
    rg <- G.getGraph mm

    -- The drive should be marked power off.
    when (any isPowered $ devAttrs sdev rg) $
      fail "false_dev should be power off"
    -- RC should now issue power on instruction
    msg <- expectNodeMsg 1000000
    debug $ "powerdownComplete: Msg: " ++ show msg
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (DrivePoweron sdev_path))
                    )

poweronComplete :: ProcessId -> M0.SDev -> Process ()
poweronComplete mm sdev = let
    sdev_path = pack $ M0.d_path sdev
    onComplete = CommandAck Nothing
                            (Just $ DrivePoweron sdev_path)
                            AckReplyPassed
  in do
    debug "poweronComplete"
    nid <- getSelfNode
    -- Confirms that the disk powerdown operation has occured.
    _ <- promulgateEQ [nid] onComplete
    _ <- expect :: Process (Published CommandAck)
    debug "poweronComplete: Command acknowledged"
    rg <- G.getGraph mm

    -- The drive should be marked power on.
    when (not $ any isPowered $ devAttrs sdev rg) $
      fail "false_dev should be power on"
    -- RC should now issue power on instruction
    msg <- expectNodeMsg 1000000
    debug $ "poweronComplete: Msg: " ++ show msg
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (SmartTest sdev_path))
                    )

smartTestComplete :: ReceivePort Set -> AckReply -> M0.SDev -> Process ()
smartTestComplete recv success sdev = let
    sdev_path = pack $ M0.d_path sdev
    smartComplete = CommandAck Nothing
                        (Just $ SmartTest sdev_path)
                        success
    status = case success of
      AckReplyPassed -> M0_NC_ONLINE
      AckReplyFailed -> M0_NC_FAILED
      AckReplyError _ -> M0_NC_FAILED
  in do
    debug "smartTestComplete"
    nid <- getSelfNode
    -- Confirms that the disk powerdown operation has occured.
    _ <- promulgateEQ [nid] smartComplete
    Set [Note fid stat] <- receiveChan recv
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
    powerdownComplete mm sdev
    poweronComplete mm sdev
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
      powerdownComplete mm sdev
      poweronComplete mm sdev
      smartTestComplete recv AckReplyPassed sdev

    -- Fail the drive one more time
    let fail_evt = Set [Note (M0.d_fid sdev) M0_NC_FAILED]
    nid <- getSelfNode
    void $ promulgateEQ [nid] fail_evt
    -- Mero should be notified that the drive should be failed.
    Set [Note _ M0_NC_FAILED] <- receiveChan recv

    return ()

testFailedSMART :: Transport -> IO ()
testFailedSMART transport = run transport interceptor test where
  interceptor _ _ = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData

    sdev <- G.getGraph mm >>= findSDev
    failDrive recv sdev
    powerdownComplete mm sdev
    poweronComplete mm sdev
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
    powerdownComplete mm sdev
    powerdownComplete mm sdev2
    poweronComplete mm sdev2
    smartTestComplete recv AckReplyPassed sdev2
    poweronComplete mm sdev
    smartTestComplete recv AckReplyPassed sdev

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

-- | SSPL emits unused_ok event for one of the drives.
testDriveRemovedBySSPL :: Transport -> IO ()
testDriveRemovedBySSPL transport = run transport interceptor test where
  interceptor rc str
    | any (("Cannot detach device"::String) `List.isPrefixOf`) (List.tails str) = usend rc ("Detached"::String)
    | otherwise = return ()
  test (TestArgs _ mm rc) rmq recv = do
    prepareSubscriptions rc rmq
    loadInitialData
    subscribe rc (Proxy :: Proxy DriveRemoved)
    let enclosure = "enclosure1"
        host      = "primus.example.com"
        devIdx    = 1
        message0 = LBS.toStrict $ encode
                                $ mkSensorResponse
                                $ mkResponseHPI host (fromIntegral devIdx) "/dev/loop1" "wwn1"
        message = LBS.toStrict $ encode $ mkSensorResponse
           $ emptySensorMessage
              { sensorResponseMessageSensor_response_typeDisk_status_drivemanager =
                Just $ mkResponseDriveManager (pack enclosure) devIdx "unused_ok" }
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message0
    usend rmq $ MQPublish "sspl_halon" "sspl_ll" message
    _ <- expect :: Process (Published DriveRemoved)
    True <- checkStorageDeviceRemoved enclosure devIdx <$> G.getGraph mm
    Set [Note _ M0_NC_TRANSIENT] <- receiveChan recv
    "Detached" <- expect :: Process String
    return ()
