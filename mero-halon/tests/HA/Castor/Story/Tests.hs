{-# LANGUAGE CPP             #-}
{-# LANGUAGE RecursiveDo     #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.Castor.Story.Tests (tests) where

import Control.Arrow (first, second)
import Control.Monad (join, when, replicateM_)
import Control.Exception
import Data.Typeable
import Data.Text (pack)

import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Data.Defaultable
import Network.CEP
import Network.Transport
import Test.Framework

import HA.EventQueue
import HA.EventQueue.Producer
import HA.EventQueue.Types
import HA.Multimap.Implementation
import HA.Multimap.Process
import HA.NodeUp
import qualified HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.Actions.Mero
    ( rgGetAllSDevs
    , ResetAttempt(..)
    )
import HA.RecoveryCoordinator.Definitions (recoveryCoordinator)
import HA.Replicator
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
import HA.Castor.Tests (initialDataAddr)
import Mero.Notification
import Mero.Notification.HAState
import HA.Resources
import HA.Resources.Castor.Initial (InitialData)
import HA.Resources.Castor
import HA.Resources.Mero hiding (Process)
import HA.Resources.Mero.Note

import HA.Service
import HA.Services.Mero
import HA.Services.SSPL
import HA.Services.SSPL.Rabbit
import HA.Services.SSPL.LL.Resources

import RemoteTables (remoteTable)

type TestReplicatedState = (EventQueue, Multimap)

remotableDecl [ [d|
  eqView :: RStateView TestReplicatedState EventQueue
  eqView = RStateView fst first

  multimapView :: RStateView TestReplicatedState Multimap
  multimapView = RStateView snd second

  testDict :: SerializableDict TestReplicatedState
  testDict = SerializableDict
  |]]

myRemoteTable :: RemoteTable
myRemoteTable = HA.Castor.Story.Tests.__remoteTableDecl remoteTable

-- | FIXME: Why do we need tryRunProcess?
tryRunProcessLocal :: Transport -> Process () -> IO ()
tryRunProcessLocal transport process =
  withTmpDirectory $
    withLocalNode transport $ \node ->
      runProcess node process

-- | Run the given action on a newly created local node.
withLocalNode :: Transport -> (LocalNode -> IO a) -> IO a
withLocalNode transport action =
  bracket
    (newLocalNode transport (myRemoteTable))
    -- FIXME: Why does this cause gibberish to be output?
    -- closeLocalNode
    (const (return ()))
    action

meroServiceProcess :: ProcessId -> ServiceProcess MeroConf
meroServiceProcess = ServiceProcess

newMeroChannel :: ProcessId -> Process (ReceivePort Set, DeclareMeroChannel)
newMeroChannel pid = do
  (sd, recv) <- newChan
  let sdChan   = TypedChannel sd
      meroChan = DeclareMeroChannel (meroServiceProcess pid) sdChan
  return (recv, meroChan)

tests :: Transport -> [TestTree]
tests transport = map (localOption (mkTimeout $ 60*1000000))
  [ testSuccess "Drive failure, successful reset and smart test success" $
    run transport testDiskFailure
  , testSuccess "Drive failure, repeated attempts to reset, hitting reset limit" $
    run transport testHitResetLimit
  , testSuccess "Drive failure, successful reset, failed smart test" $
    run transport testFailedSMART
  , testSuccess "Drive failure, second drive fails whilst handling to reset attempt" $
    run transport testSecondReset
  , testSuccess "Drive failure, reset attempt, no reponse from SSPL" $
    run transport testSSPLNoResponse
  ]

createRGroup :: Process (MC_RG TestReplicatedState)
createRGroup = do
    nid <- getSelfNode
    tmpRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000 [nid]
                 ((Nothing,[]), fromList [])
    join $ unClosure tmpRGroup

run :: Transport
    -> (ProcessId -> ProcessId -> Process ())
    -> IO ()
run transport k = tryRunProcessLocal transport $ do
    nid <- getSelfNode
    let args = HA.RecoveryCoordinator.Mero.IgnitionArguments [nid]
    rGroup <- createRGroup
    eq <- startEventQueue (viewRState $(mkStatic 'eqView) rGroup)
    rec (mm, rc) <- (,)
                    <$> (spawnLocal $ do
                          () <- expect
                          link rc
                          multimap (viewRState $(mkStatic 'multimapView) rGroup))
                    <*> (spawnLocal $ do
                          () <- expect
                          recoveryCoordinator args eq mm)
    usend eq rc
    usend mm ()
    usend rc ()
    nodeUp ([nid], 2000000)
    k rc mm

findSDev :: G.Graph -> Process SDev
findSDev rg =
  case rgGetAllSDevs rg of
    sdev:_ -> return sdev
    _      -> fail "Can't find a SDev"

find2SDev :: G.Graph -> Process SDev
find2SDev rg =
  case rgGetAllSDevs rg of
    _:sdev:_ -> return sdev
    _        -> fail "Can't find more than 2 SDevs"

devAttrs :: SDev -> G.Graph -> [StorageDeviceAttr]
devAttrs sdev rg =
  [ attr | dev  <- G.connectedTo sdev IsOnHardware rg :: [Disk]
         , sd   <- G.connectedTo dev At rg :: [StorageDevice]
         , attr <- G.connectedTo sd At rg :: [StorageDeviceAttr]
         ]

isPowered :: StorageDeviceAttr -> Bool
isPowered SDPowered = True
isPowered _         = False

ongoingReset :: StorageDeviceAttr -> Bool
ongoingReset SDOnGoingReset = True
ongoingReset _              = False

startSSPLService :: Process ()
startSSPLService = do
  nid <- getSelfNode
  let conf =
        SSPLConf (ConnectionConf (Configured "127.0.0.1")
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

  return ()

startMeroServiceMock :: Process (ReceivePort Set)
startMeroServiceMock = do
    nid <- getSelfNode
    pid <- getSelfPid
    (recv, channel) <- newMeroChannel pid
    _ <- promulgateEQ [nid] channel
    return recv

spawnMockRabbitMQ :: Process ()
spawnMockRabbitMQ = do
    _ <- spawnLocal $ rabbitMQProxy $ ConnectionConf (Configured "localhost")
         (Configured "/")
         ("guest")
         ("guest")
    return ()

resetAttemptThreshold :: Int
resetAttemptThreshold = 10

testDiskFailure :: ProcessId -> ProcessId -> Process ()
testDiskFailure rc mm = do
    spawnMockRabbitMQ
    recv <- startMeroServiceMock
    startSSPLService

    nid <- getSelfNode
    let init_msg = initialDataAddr "192.0.2.1" "192.0.2.2"

    subscribe rc (Proxy :: Proxy (HAEvent InitialData))
    -- We populate the graph with confc context.
    _ <- promulgateEQ [nid] init_msg

    -- We wait the RC finished to populate the RC.
    _ <- expect :: Process (Published (HAEvent InitialData))

    testDiskFailureBase rc mm recv

testHitResetLimit :: ProcessId -> ProcessId -> Process ()
testHitResetLimit rc mm = do
    spawnMockRabbitMQ
    recv <- startMeroServiceMock
    startSSPLService

    nid <- getSelfNode
    let init_msg = initialDataAddr "192.0.2.1" "192.0.2.2"

    subscribe rc (Proxy :: Proxy (HAEvent InitialData))
    -- We populate the graph with confc context.
    _ <- promulgateEQ [nid] init_msg

    -- We wait the RC finished to populate the RC.
    _ <- expect :: Process (Published (HAEvent InitialData))

    replicateM_ (resetAttemptThreshold + 1) $
      testDiskFailureBase rc mm recv

    -- Mero should be notified that the drive should be transient.
    Set [Note _ M0_NC_FAILED] <- receiveChan recv

    return ()

testDiskFailureBase :: ProcessId -> ProcessId -> ReceivePort Set -> Process ()
testDiskFailureBase rc mm recv= do
    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy (HAEvent CommandAck))
    subscribe rc (Proxy :: Proxy ResetAttempt)

    sdev <- G.getGraph mm >>= findSDev

    let fail_evt = Set [Note (d_fid sdev) M0_NC_FAILED]
        sdev_path = pack $ d_path sdev

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
                        AckReplyPassed

    -- Confirms that the disk smart test operation has been completed.
    _ <- promulgateEQ [nid] smartComplete

    -- Mero should be notified that the drive should be online.
    Set [Note _ M0_NC_ONLINE] <- receiveChan recv

    return ()

testFailedSMART :: ProcessId -> ProcessId -> Process ()
testFailedSMART rc mm = do
    spawnMockRabbitMQ
    recv <- startMeroServiceMock
    startSSPLService

    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy (HAEvent CommandAck))
    subscribe rc (Proxy :: Proxy ResetAttempt)

    sdev <- G.getGraph mm >>= findSDev

    let fail_evt = Set [Note (d_fid sdev) M0_NC_FAILED]
        sdev_path = pack $ d_path sdev

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

testSecondReset :: ProcessId -> ProcessId -> Process ()
testSecondReset rc mm = do
    spawnMockRabbitMQ
    recv <- startMeroServiceMock
    startSSPLService

    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy ResetAttempt)

    sdev <- G.getGraph mm >>= findSDev
    sdev2 <- G.getGraph mm >>= find2SDev

    let fail_evt = Set [Note (d_fid sdev) M0_NC_FAILED]
        fail2_evt = Set [Note (d_fid sdev2) M0_NC_FAILED]

    -- We a drive failure note to the RC.
    _ <- promulgateEQ [nid] fail_evt

    -- Waits 'ResetAttempt' has been handle for the first 'SDev'.
    _ <- expect :: Process (Published ResetAttempt)

    -- Reports SDev 2 has failed too.
    _ <- promulgateEQ [nid] fail2_evt

    -- Proves that the RC handles multiple drive failures and reset attempts at
    -- the same time.
    _ <- expect :: Process (Published ResetAttempt)

    return ()

testSSPLNoResponse :: ProcessId -> ProcessId -> Process ()
testSSPLNoResponse rc mm = do
    spawnMockRabbitMQ
    recv <- startMeroServiceMock
    startSSPLService

    nid <- getSelfNode

    subscribe rc (Proxy :: Proxy (HAEvent CommandAck))
    subscribe rc (Proxy :: Proxy ResetAttempt)

    sdev <- G.getGraph mm >>= findSDev

    let fail_evt = Set [Note (d_fid sdev) M0_NC_FAILED]
        sdev_path = pack $ d_path sdev

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
