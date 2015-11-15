{-# LANGUAGE CPP             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo     #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.Castor.Story.Tests (mkTests) where

import HA.EventQueue.Producer
import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Mero
    ( rgGetAllSDevs )
import HA.RecoveryCoordinator.Rules.Castor
import qualified HA.ResourceGraph as G
import HA.Castor.Tests (initialDataAddr)
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

import Control.Monad (join, when, replicateM_)
import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Node
import Control.Exception as E hiding (assert)

import Data.Aeson (decode)
import Data.Typeable
import Data.Text (pack)
import Data.Defaultable

import Network.AMQP
import Network.CEP
import Network.Transport

import Test.Framework
import Test.Tasty.HUnit (Assertion)
import TestRunner

debug :: String -> Process ()
debug = liftIO . appendFile "/tmp/halon.debug"

myRemoteTable :: RemoteTable
myRemoteTable = TestRunner.__remoteTableDecl remoteTable

meroServiceProcess :: ProcessId -> ServiceProcess MeroConf
meroServiceProcess = ServiceProcess

newMeroChannel :: ProcessId -> Process (ReceivePort Set, DeclareMeroChannel)
newMeroChannel pid = do
  (sd, recv) <- newChan
  let sdChan   = TypedChannel sd
      meroChan = DeclareMeroChannel (meroServiceProcess pid) sdChan
  return (recv, meroChan)

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
        , testSuccess "Drive failure, reset attempt, no reponse from SSPL" $
          testSSPLNoResponse transport
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
  runTest 1 20 15000000 transport myRemoteTable $ \[n] -> do
    self <- getSelfPid
    withTrackingStation emptyRules $ \ta -> do
      registerInterceptor $ \string ->
        case string of
          str@"Starting service sspl"   -> usend self str
          x -> interceptor self x

      startSSPLService
      meroRP <- startMeroServiceMock
      rmq <- spawnMockRabbitMQ
      -- Run the test

      test ta rmq meroRP

      -- Tear down the test
      _ <- promulgateEQ [localNodeId n] $ encodeP $
            ServiceStopRequest (Node $ localNodeId n) sspl
      _ <- receiveTimeout 1000000 []
      kill rmq "end of game"
  where
    startSSPLService :: Process ()
    startSSPLService = do
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
                                   (BindConf (Configured "sspl_halon")
                                                (Configured "sspl_ll")
                                                (Configured "sspl_halon"))
                                   (BindConf (Configured "sspl_command_ack")
                                                (Configured "halon_ack")
                                                (Configured "sspl_command_ack"))
                                   (Configured 1000000))

          msg = ServiceStartRequest Start (HA.Resources.Node nid) sspl conf []

      _ <- promulgateEQ [nid] $ encodeP msg
      ("Starting service sspl" :: String) <- expect

      return ()

    startMeroServiceMock :: Process (ReceivePort Set)
    startMeroServiceMock = do
        nid <- getSelfNode
        pid <- getSelfPid
        (recv, channel) <- newMeroChannel pid
        _ <- promulgateEQ [nid] channel
        return recv

    spawnMockRabbitMQ :: Process ProcessId
    spawnMockRabbitMQ = do
      pid <- spawnLocal $ rabbitMQProxy $ ConnectionConf (Configured "localhost")
             (Configured "/")
             ("guest")
             ("guest")
      link pid
      return pid

findSDev :: G.Graph -> Process M0.SDev
findSDev rg =
  case rgGetAllSDevs rg of
    sdev:_ -> return sdev
    _      -> fail "Can't find a M0.SDev"

find2SDev :: G.Graph -> Process M0.SDev
find2SDev rg =
  case rgGetAllSDevs rg of
    _:sdev:_ -> return sdev
    _        -> fail "Can't find more than 2 SDevs"

devAttrs :: M0.SDev -> G.Graph -> [StorageDeviceAttr]
devAttrs sdev rg =
  [ attr | dev  <- G.connectedTo sdev M0.IsOnHardware rg :: [M0.Disk]
         , sd   <- G.connectedTo dev M0.At rg :: [StorageDevice]
         , attr <- G.connectedTo sd Has rg :: [StorageDeviceAttr]
         ]

isPowered :: StorageDeviceAttr -> Bool
isPowered SDPowered = True
isPowered _         = False

ongoingReset :: StorageDeviceAttr -> Bool
ongoingReset SDOnGoingReset = True
ongoingReset _              = False

expectNodeMsg :: Process (Maybe ActuatorRequestMessageActuator_request_typeNode_controller)
expectNodeMsg = do
  msg <- return . decode =<< expect
  return . join
    $ actuatorRequestMessageActuator_request_typeNode_controller
    . actuatorRequestMessageActuator_request_type
    . actuatorRequestMessage
    <$> msg

testDiskFailureBase :: TestArgs
                    -> ProcessId -- ^ RabbitMQ Proxy
                    -> ReceivePort Set
                    -> Process ()
testDiskFailureBase (TestArgs _ mm rc) rmq recv = do
    debug "244"
    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy (HAEvent CommandAck))
    subscribe rc (Proxy :: Proxy ResetAttempt)
    -- Subscribe to SSPL channels
    usend rmq . MQSubscribe "sspl_halon" =<< getSelfPid
    usend rmq . MQSubscribe "sspl_iem" =<< getSelfPid

    debug "251"
    sdev <- G.getGraph mm >>= findSDev

    let fail_evt = Set [Note (M0.d_fid sdev) M0_NC_FAILED]
        sdev_path = pack $ M0.d_path sdev

    -- We a drive failure note to the RC.
    _ <- promulgateEQ [nid] fail_evt
    debug "260"
    -- Mero should be notified that the drive should be transient.
    Set [Note _ M0_NC_TRANSIENT] <- receiveChan recv
    debug "263"
    -- The RC should issue a 'ResetAttempt' and should be handled.
    _ <- expect :: Process (Published ResetAttempt)
    -- We should see `ResetAttempt` from SSPL
    msg <- expectNodeMsg
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (DrivePowerdown sdev_path))
                    )
    debug "272"
    -- TODO send this from SSPL side
    let downComplete = CommandAck Nothing
                                  (Just $ DrivePowerdown sdev_path)
                                  AckReplyPassed

    -- Confirms that the disk powerdown operation has occured.
    _ <- promulgateEQ [nid] downComplete

    _ <- expect :: Process (Published (HAEvent CommandAck))
    tmp2_rg <- G.getGraph mm

    -- The drive should be marked power off.
    when (any isPowered $ devAttrs sdev tmp2_rg) $
      fail "false_dev should be power off"

    -- RC should now issue power on instruction
    msg <- expectNodeMsg
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (DrivePoweron sdev_path))
                    )

    -- TODO send this from SSPL side
    let onComplete = CommandAck Nothing
                     (Just $ DrivePoweron sdev_path)
                     AckReplyPassed

    -- Confirms that the disk poweron operation has occured.
    _ <- promulgateEQ [nid] onComplete
    _ <- expect :: Process (Published (HAEvent CommandAck))
    tmp3_rg <- G.getGraph mm

    -- The drive should be marked power on.
    when (not $ any isPowered $ devAttrs sdev tmp3_rg) $
      fail "false_dev should be power on"

    -- RC should now issue power on instruction
    msg <- expectNodeMsg
    assert $ msg
            == Just (ActuatorRequestMessageActuator_request_typeNode_controller
                      (nodeCmdString (SmartTest sdev_path))
                    )

    let smartComplete = CommandAck Nothing
                        (Just $ SmartTest sdev_path)
                        AckReplyPassed

    -- Confirms that the disk smart test operation has been completed.
    _ <- promulgateEQ [nid] smartComplete

    -- Mero should be notified that the drive should be online.
    Set [Note _ M0_NC_ONLINE] <- receiveChan recv

    return ()

testDiskFailure :: Transport -> IO ()
testDiskFailure transport = run transport interceptor test where
  interceptor _ _ = return ()
  test ta@(TestArgs _ mm rc) rmq recv = do
    debug "335"
    nid <- getSelfNode
    let init_msg = initialDataAddr "192.0.2.1" "192.0.2.2" 8
    debug "338"
    subscribe rc (Proxy :: Proxy (HAEvent InitialData))
    -- We populate the graph with confc context.
    _ <- promulgateEQ [nid] init_msg
    debug "342"
    -- We wait the RC finished to populate the RC.
    _ <- expect :: Process (Published (HAEvent InitialData))
    debug "345"
    testDiskFailureBase ta rmq recv

testHitResetLimit :: Transport -> IO ()
testHitResetLimit transport = run transport interceptor test where
  interceptor _ _ = return ()
  test ta@(TestArgs _ mm rc) rmq recv = do
    nid <- getSelfNode
    let init_msg = initialDataAddr "192.0.2.1" "192.0.2.2" 8

    subscribe rc (Proxy :: Proxy (HAEvent InitialData))
    -- We populate the graph with confc context.
    _ <- promulgateEQ [nid] init_msg

    -- We wait the RC finished to populate the RC.
    _ <- expect :: Process (Published (HAEvent InitialData))

    replicateM_ (resetAttemptThreshold + 1) $
      testDiskFailureBase ta rmq recv

    -- Mero should be notified that the drive should be transient.
    Set [Note _ M0_NC_FAILED] <- receiveChan recv

    return ()

testFailedSMART :: Transport -> IO ()
testFailedSMART transport = run transport interceptor test where
  interceptor _ _ = return ()
  test ta@(TestArgs _ mm rc) rmq recv = do
    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy (HAEvent CommandAck))
    subscribe rc (Proxy :: Proxy ResetAttempt)

    sdev <- G.getGraph mm >>= findSDev

    let fail_evt = Set [Note (M0.d_fid sdev) M0_NC_FAILED]
        sdev_path = pack $ M0.d_path sdev

    -- We a drive failure note to the RC.
    _ <- promulgateEQ [nid] fail_evt

    -- Mero should be notified that the drive should be transient.
    Set [Note _ M0_NC_TRANSIENT] <- receiveChan recv

    -- The RC should issue a 'ResetAttempt' and should be handled.
    _ <- expect :: Process (Published ResetAttempt)

    let downComplete = CommandAck Nothing
                                  (Just $ DrivePowerdown sdev_path)
                                  AckReplyPassed

    -- Confirms that the disk powerdown operation has occured.
    _ <- promulgateEQ [nid] downComplete

    _ <- expect :: Process (Published (HAEvent CommandAck))
    tmp2_rg <- G.getGraph mm

    -- The drive should be marked power off.
    when (any isPowered $ devAttrs sdev tmp2_rg) $
      fail "false_dev should be power off"

    let onComplete = CommandAck Nothing
                     (Just $ DrivePoweron sdev_path)
                     AckReplyPassed

    -- Confirms that the disk poweron operation has occured.
    _ <- promulgateEQ [nid] onComplete
    _ <- expect :: Process (Published (HAEvent CommandAck))
    tmp3_rg <- G.getGraph mm

    -- The drive should be marked power on.
    when (not $ any isPowered $ devAttrs sdev tmp3_rg) $
      fail "false_dev should be power on"

    let smartComplete = CommandAck Nothing
                        (Just $ SmartTest sdev_path)
                        AckReplyFailed

    -- Confirms that the disk smart test operation has been completed.
    _ <- promulgateEQ [nid] smartComplete

    -- Mero should be notified that the drive should be in failure state.
    Set [Note _ M0_NC_FAILED] <- receiveChan recv

    return ()

testSecondReset :: Transport -> IO ()
testSecondReset transport = run transport interceptor test where
  interceptor _ _ = return ()
  test ta@(TestArgs _ mm rc) rmq recv = do
    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy ResetAttempt)

    sdev <- G.getGraph mm >>= findSDev
    sdev2 <- G.getGraph mm >>= find2SDev

    let fail_evt = Set [Note (M0.d_fid sdev) M0_NC_FAILED]
        fail2_evt = Set [Note (M0.d_fid sdev2) M0_NC_FAILED]

    -- We a drive failure note to the RC.
    _ <- promulgateEQ [nid] fail_evt

    -- Waits 'ResetAttempt' has been handle for the first 'M0.SDev'.
    _ <- expect :: Process (Published ResetAttempt)

    -- Reports M0.SDev 2 has failed too.
    _ <- promulgateEQ [nid] fail2_evt

    -- Proves that the RC handles multiple drive failures and reset attempts at
    -- the same time.
    _ <- expect :: Process (Published ResetAttempt)

    return ()

testSSPLNoResponse :: Transport -> IO ()
testSSPLNoResponse transport = run transport interceptor test where
  interceptor _ _ = return ()
  test ta@(TestArgs _ mm rc) rmq recv = do
    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy (HAEvent CommandAck))
    subscribe rc (Proxy :: Proxy ResetAttempt)

    sdev <- G.getGraph mm >>= findSDev

    let fail_evt = Set [Note (M0.d_fid sdev) M0_NC_FAILED]
        sdev_path = pack $ M0.d_path sdev

    -- We a drive failure note to the RC.
    _ <- promulgateEQ [nid] fail_evt

    -- Mero should be notified that the drive should be transient.
    Set [Note _ M0_NC_TRANSIENT] <- receiveChan recv

    -- The RC should issue a 'ResetAttempt' and should be handled.
    _ <- expect :: Process (Published ResetAttempt)

    let downComplete = CommandAck Nothing
                                  (Just $ DrivePowerdown sdev_path)
                                  AckReplyPassed

    -- Confirms that the disk powerdown operation has occured.
    _ <- promulgateEQ [nid] downComplete

    _ <- expect :: Process (Published (HAEvent CommandAck))
    tmp2_rg <- G.getGraph mm

    -- The drive should be marked power off.
    when (any isPowered $ devAttrs sdev tmp2_rg) $
      fail "false_dev should be power off"

    let onComplete = CommandAck Nothing
                     (Just $ DrivePoweron sdev_path)
                     AckReplyPassed

    -- Confirms that the disk poweron operation has occured.
    _ <- promulgateEQ [nid] onComplete
    _ <- expect :: Process (Published (HAEvent CommandAck))
    tmp3_rg <- G.getGraph mm

    -- The drive should be marked power on.
    when (not $ any isPowered $ devAttrs sdev tmp3_rg) $
      fail "false_dev should be power on"

    return ()
