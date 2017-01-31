{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}
-- |
-- Module    : HA.Castor.Story.Tests
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- General Castor story tests
module HA.Castor.Story.Tests (mkTests) where

import           Control.Arrow ((&&&))
import           Control.Distributed.Process hiding (bracket)
import           Control.Distributed.Process.Node
import           Control.Exception as E hiding (assert)
import           Control.Lens hiding (to)
import           Control.Monad (forM_, replicateM_, void)
import           Data.Aeson (decode, encode)
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString.Lazy as LBS
import           Data.Maybe (isJust, listToMaybe, maybeToList)
import           Data.Proxy
import           Data.Text (pack)
import           Data.Typeable
import qualified Data.UUID as UUID
import           Data.UUID.V4 (nextRandom)
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.Multimap
import           HA.RecoveryCoordinator.Castor.Drive
import           HA.RecoveryCoordinator.Castor.Drive.Actions
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero.Actions.Conf (encToM0Enc)
import           HA.RecoveryCoordinator.RC.Subscription
import           HA.Replicator
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Services.SSPL
import           HA.Services.SSPL.LL.Resources
import           HA.Services.SSPL.Rabbit
import           Helper.Runner
import           Helper.SSPL
import           Mero.ConfC (Fid(..))
import           Mero.Notification.HAState
import           Network.AMQP
import           Network.CEP
import           Network.Transport
import           SSPL.Bindings
import           Test.Framework
import           Test.Tasty.HUnit (assertEqual, assertFailure)

ssplTimeout :: Int
ssplTimeout = 10*1000000

data ThatWhichWeCallADisk = ADisk
  { aDiskSD :: StorageDevice -- ^ Has a storage device
  , aDiskMero :: Maybe (M0.SDev) -- ^ Maybe has a corresponding Mero device
  , aDiskPath :: String -- ^ Has a path
  , aDiskWWN :: String -- ^ Has a WWN
  } deriving (Show)

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e::AMQPException) -> return $ \_->
      -- If rabbitmq doesn't work there is no use in this tests, just fail them.
      [testSuccess "Drive failure tests"  $ error $ "RabbitMQ error: " ++ show e ]
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
        , testSuccess "Halon powers down disk on failure" $
          testDrivePoweredDown transport pg
        , testSuccess "RAID reassembles after expander reset" $
          testExpanderResetRAIDReassemble transport pg
        ]

-- | Get system hostname of the given 'NodeId' from RG.
getHostName :: TestSetup
            -> NodeId
            -> Process (Maybe String)
getHostName ts nid = do
  rg <- G.getGraph (_ts_mm ts)
  return $! case G.connectedFrom Runs (Node nid) rg of
    Just (Host hn) -> Just hn
    _ -> Nothing

-- | Keep checking RG until the given predicate on it holds. Useful
-- when notifications from RC don't cut it: for example, a
-- notification goes out before graph sync. If we rely on notification
-- and ask for graph, we might still see the old state.
--
-- Note that this works on a timeout loop: even if a change in the
-- graph happened, we're not guaranteed to see it with this. That is,
-- the graph might update again before we check it and we miss the
-- update all together therefore this shouldn't be used with
-- predicates that will only hold momentarily.
waitUntilGraph :: StoreChan            -- ^ Where to retrieve current RG from.
               -> Int                  -- ^ Time between retries in seconds.
               -> Int                  -- ^ Number of retries before giving up.
               -> (G.Graph -> Maybe a) -- ^ Predicate on the graph.
               -> Process (Maybe a)
waitUntilGraph _ _ tries _ | tries <= 0 = return Nothing
waitUntilGraph mm interval tries p = do
  rg <- G.getGraph mm
  case p rg of
    Nothing -> do
      _ <- receiveTimeout (interval * 1000000) []
      waitUntilGraph mm interval (tries - 1) p
    r -> return r

-- | Waits until given object enters state. Caveats from
-- 'waitUntilGraph' apply.
waitState :: HasConfObjectState a
          => a                        -- ^ Object to examine
          -> StoreChan                -- ^ Where to retrieve current RG from.
          -> Int                      -- ^ Time between tries, seconds
          -> Int                      -- ^ Number of retries
          -> (StateCarrier a -> Bool) -- ^ Predicate on state
          -> Process (Maybe (StateCarrier a))
waitState obj mm interval ts p = waitUntilGraph mm interval ts $ \rg ->
  let st = HA.Resources.Mero.Note.getState obj rg
  in if p st then Just st else Nothing

findSDev :: G.Graph -> Process ThatWhichWeCallADisk
findSDev rg =
  let dvs = [ ADisk storage (Just sdev) path wwn
            | sdev <- G.getResourcesOfType rg :: [M0.SDev]
            , Just (disk :: M0.Disk) <- [G.connectedTo sdev M0.IsOnHardware rg]
            , Just (storage :: StorageDevice) <- [G.connectedTo disk M0.At rg]
            -- , DIPath path <- G.connectedTo storage Has rg
            , path <- return "path" -- DIPath path <- G.connectedTo storage Has rg
            , DIWWN wwn <- G.connectedTo storage Has rg
            -- , wwn <- return "wwn" --DIWWN wwn <- G.connectedTo storage Has rg
            ]
  in case dvs of
    dv:_ -> return dv
    _    -> do liftIO $ assertFailure "Can't find a M0.SDev or its serial number"
               error "Unreachable"

-- | Find 'Enclosure' that 'StorageDevice' ('aDiskSD') belongs to.
findDiskEnclosure :: ThatWhichWeCallADisk -> G.Graph -> Maybe Enclosure
findDiskEnclosure disk rg = slotEnclosure <$> G.connectedTo (aDiskSD disk) Has rg

find2SDev :: G.Graph -> Process ThatWhichWeCallADisk
find2SDev rg =
  let dvs = [ ADisk storage (Just sdev) path wwn
            | sdev <- G.getResourcesOfType rg :: [M0.SDev]
            , Just (disk :: M0.Disk) <- [G.connectedTo sdev M0.IsOnHardware rg]
            , Just (storage :: StorageDevice) <- [G.connectedTo disk M0.At rg]
            , DIPath path <- G.connectedTo storage Has rg
            , DIWWN wwn <- G.connectedTo storage Has rg
            ]
  in case dvs of
    _:dv:_ -> return dv
    _    -> do liftIO $ assertFailure "Can't find a second M0.SDev or its serial number"
               error "Unreachable"

-- | Check if specified device have RemovedAt attribute.
checkStorageDeviceRemoved :: Enclosure -> Int -> G.Graph -> Bool
checkStorageDeviceRemoved enc idx rg = Prelude.null $
  [ () | slot@(Slot enc' idx') <- G.connectedTo enc Has rg
       , Just{} <- [G.connectedFrom Has slot rg :: Maybe StorageDevice]
       , enc == enc' && idx == idx'
       ]

-- | Announce a new 'StorageDevice' (through 'ThatWhichWeCallADisk')
-- to the RC through an HPI message. This is useful when the disk is
-- not in the initial data to begin with such as in the case of
-- metadata/RAID drives.
announceNewSDev :: Enclosure -> ThatWhichWeCallADisk -> TestSetup -> Process ()
announceNewSDev enc@(Enclosure enclosureName) sdev ts = do
  rg <- G.getGraph (_ts_mm ts)
  let Host host : _ = G.connectedTo enc Has rg
      devIdx = succ . maximum . map slotIndex $ G.connectedTo enc Has rg
      slot = Slot enc devIdx
      message = LBS.toStrict . encode . mkSensorResponse $ mkResponseHPI
        (pack host) (pack enclosureName)
        ((\(StorageDevice sn) -> pack sn) $ aDiskSD sdev) (fromIntegral devIdx)
        (pack $ aDiskPath sdev)
        (pack $ aDiskWWN sdev)
        True True
  withSubscription [processNodeId $ _ts_rc ts] (Proxy :: Proxy DriveInserted) $ do
    usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" message
    let isOurDI (DriveInserted _ _ slot' sdev' True) = slot' == slot && sdev' == aDiskSD sdev
        isOurDI _ = False
    r <- receiveTimeout 10000000
      [ matchIf (\(Published v _) -> isOurDI v) (\_ -> return ()) ]
    case r of
      Nothing -> fail "announceNewSDev: timed out waiting for DriveInserted"
      Just{} -> return ()
  Just{} <- waitUntilGraph (_ts_mm ts) 1 10 $ \rg' ->
    -- Check that the drive is reachable from the enclosure, through
    -- the slot.
    let devs = [ d | slot'@Slot{} <- G.connectedTo enc Has rg'
                   , d <- maybeToList $ G.connectedFrom Has slot' rg' ]
    in return $! if aDiskSD sdev `elem` devs then Just () else Nothing
  return ()

expectNodeMsg :: Int -> Process (Maybe ActuatorRequestMessageActuator_request_typeNode_controller)
expectNodeMsg = (fmap (fmap snd)) . expectNodeMsgUid

expectNodeMsgUid :: Int -> Process (Maybe (Maybe UUID, ActuatorRequestMessageActuator_request_typeNode_controller))
expectNodeMsgUid = expectActuatorMsg
  (actuatorRequestMessageActuator_request_typeNode_controller
  . actuatorRequestMessageActuator_request_type
  . actuatorRequestMessage
  )

expectActuatorMsg :: (ActuatorRequest -> Maybe b) -> Int -> Process (Maybe (Maybe UUID, b))
expectActuatorMsg f t = do
    let decodeBS = decode . LBS.fromStrict
    let decodable msg = isJust $ decodeBS msg >>= f
    receiveTimeout t
      [ matchIf (\(MQMessage _ msg) -> decodable msg)
                (\(MQMessage _ msg) ->
                   let Just r = pull2nd . (getUUID &&& f) =<< decodeBS msg
                   in return r)
      ]
  where
    getUUID arm = do
      uid_s <- actuatorRequestMessageSspl_ll_msg_headerUuid
                . actuatorRequestMessageSspl_ll_msg_header
                . actuatorRequestMessage
                $ arm
      UUID.fromText uid_s
    pull2nd x = (,) <$> pure (fst x) <*> snd x

--------------------------------------------------------------------------------
-- Test primitives
--------------------------------------------------------------------------------

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
failDrive :: TestSetup -> ThatWhichWeCallADisk -> Process ()
failDrive _ (ADisk _ Nothing _ _) = error "Cannot fail a non-Mero disk."
failDrive ts (ADisk (StorageDevice serial) (Just sdev) _ _) = do
  let tserial = pack serial
  sayTest "failDrive"
  -- We a drive failure note to the RC.
  _ <- promulgateEQ [processNodeId $ _ts_rc ts] (mkSDevFailedMsg sdev)

  -- Mero should be notified that the drive should be transient.
  Just{} <- waitState sdev (_ts_mm ts) 2 10 $ \case
    M0.SDSTransient _ -> True
    _ -> False
  sayTest "failDrive: Transient state set"
  -- The RC should issue a 'ResetAttempt' and should be handled.
  _ :: HAEvent ResetAttempt <- expectPublished
  -- We should see `ResetAttempt` from SSPL
  let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
          $ nodeCmdString (DriveReset tserial)
  liftIO . assertEqual "drive reset command is issued"  (Just cmd) =<< expectNodeMsg ssplTimeout
  sayTest "failDrive: OK"

resetComplete :: ProcessId -- ^ RC
              -> StoreChan -- ^ MM
              -> ThatWhichWeCallADisk -- ^ Disk thing we're working on
              -> AckReply -- ^ Smart result
              -> Process ()
resetComplete rc mm adisk@(ADisk stord@(StorageDevice serial) m0sdev _ _) success = do
  let tserial = pack serial
      resetCmd = CommandAck Nothing (Just $ DriveReset tserial) AckReplyPassed
      smartStatus = case success of
        AckReplyPassed -> M0.SDSOnline
        _ -> M0.SDSFailed
      smartComplete = CommandAck Nothing (Just $ SmartTest tserial) success
  sayTest "resetComplete"
  -- Send 'SpielDeviceDetached' to the RC
  forM_ m0sdev $ \sd -> usend rc $ SpielDeviceDetached sd (Right ())
  -- Send 'DriveOK'
  uuid <- liftIO nextRandom
  Just enc <- findDiskEnclosure adisk <$> G.getGraph mm
  rg <- G.getGraph mm
  Just node <- return $ do
    e :: Enclosure <- findDiskEnclosure adisk rg
    listToMaybe $ do
      h :: Host <- G.connectedTo e Has rg
      G.connectedTo h Runs rg

  _ <- usend rc $ DriveOK uuid node (Slot enc 0) stord
  _ <- promulgateEQ [processNodeId rc] resetCmd
  let smartTestRequest = ActuatorRequestMessageActuator_request_typeNode_controller
                       $ nodeCmdString (SmartTest tserial)
  sayTest "Waiting for SMART request."
  liftIO . assertEqual "RC requested smart test." (Just smartTestRequest)
              =<< expectNodeMsg ssplTimeout
  sayTest $ "Sending SMART completion message: " ++ show smartComplete
  -- Confirms that the disk powerdown operation has occured.
  _ <- promulgateEQ [processNodeId rc] smartComplete

  -- If the sdev is there
  forM_ m0sdev $ \sdev -> do
    -- Send 'SpielDeviceAttached' to the RC
    usend rc $ SpielDeviceAttached sdev (Right ())

    -- Wait for reset job to finish. Check we have a reply for the
    -- right device then check it's the expected reply.
    _ <- expectPublishedIf $ \case
      ResetSuccess stord' -> stord == stord' && success == AckReplyPassed
      ResetFailure stord' -> stord == stord' && success /= AckReplyPassed
    Just{} <- waitState sdev mm 2 10 (== smartStatus)
    sayTest "Reset finished, device in expected state."

--------------------------------------------------------------------------------
-- Actual tests
--------------------------------------------------------------------------------

testDiskFailure :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDiskFailure transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
  sdev <- G.getGraph (_ts_mm ts) >>= findSDev
  failDrive ts sdev
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyPassed

testHitResetLimit :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testHitResetLimit transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
  sdev <- G.getGraph (_ts_mm ts) >>= findSDev
  let resetAttemptThreshold = _hv_drive_reset_max_retries defaultHalonVars
  replicateM_ (resetAttemptThreshold + 1) $ do
    sayTest "============== FAILURE START ================================"
    failDrive ts sdev
    resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyPassed
    sayTest "============== FAILURE Finish ================================"

  forM_ (aDiskMero sdev) $ \m0sdev -> do
    -- Fail the drive one more time
    void . promulgateEQ [processNodeId $ _ts_rc ts] $ mkSDevFailedMsg m0sdev
    Just M0.SDSFailed <- waitState m0sdev (_ts_mm ts) 2 10 (== M0.SDSFailed)
    return ()

testFailedSMART :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailedSMART transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
  sdev <- G.getGraph (_ts_mm ts) >>= findSDev
  failDrive ts sdev
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyFailed

testSecondReset :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testSecondReset transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
  sdev <- G.getGraph (_ts_mm ts) >>= findSDev
  sdev2 <- G.getGraph (_ts_mm ts) >>= find2SDev
  failDrive ts sdev
  failDrive ts sdev2
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev2 AckReplyPassed
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyPassed

-- | Test that when a message about a drive marked as not installed
-- arrives to SSPL, the drive is removed from the slot and eventually
-- becomes transient.
testDriveRemovedBySSPL :: (Typeable g, RGroup g)
                       => Transport -> Proxy g -> IO ()
testDriveRemovedBySSPL transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy DriveRemoved)
  rg <- G.getGraph (_ts_mm ts)
  sdev <- findSDev rg
  let Just enc@(Enclosure enclosureName) = findDiskEnclosure sdev rg

  -- Find the host on which this device is actually on
  Just (Host host) <- return $ do
    d :: M0.Disk <- G.connectedFrom M0.At (aDiskSD sdev) rg
    c :: M0.Controller <- G.connectedFrom M0.IsParentOf d rg
    G.connectedTo c M0.At rg

  let Just (Slot _ devIdx) = aDiskMero sdev >>= \sd -> G.connectedTo sd M0.At rg
      message = LBS.toStrict . encode . mkSensorResponse $ mkResponseHPI
                  (pack host) (pack enclosureName)
                  (pack $ (\(StorageDevice sn) -> sn) $ aDiskSD sdev)
                  (fromIntegral devIdx)
                  (pack $ aDiskPath sdev)
                  (pack $ aDiskWWN sdev)
                  False True
  -- For now the device is still in the slot.
  False <- checkStorageDeviceRemoved enc devIdx <$> G.getGraph (_ts_mm ts)
  usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" message
  Just{} <- expectTimeout ssplTimeout :: Process (Maybe (Published DriveRemoved))

  -- Wait until drive gets removed from the slot.
  Just{} <- waitUntilGraph (_ts_mm ts) 1 10 $ \rg' ->
    let devs = [ d | slot'@Slot{} <- G.connectedTo enc Has rg'
                   , d <- maybeToList $ G.connectedFrom Has slot' rg' ]
    in if aDiskSD sdev `notElem` devs then Just () else Nothing

  -- ruleDriveRemoved.mkDetachDisk.detachDisk can't work without mero
  -- worker. Simply emit the event as if the device got detached.
  forM_ (aDiskMero sdev) $ \sd -> do
    usend (_ts_rc ts) $ SpielDeviceDetached sd (Right ())
    Just{} <- waitState sd (_ts_mm ts) 2 10 $ \case
      M0.SDSTransient{} -> True
      _ -> False
    return ()

-- | Test that a failed drive powers off successfully
testDrivePoweredDown :: (Typeable g, RGroup g)
                      => Transport -> Proxy g -> IO ()
testDrivePoweredDown transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy DriveFailed)
  rg <- G.getGraph (_ts_mm ts)
  eid <- liftIO $ nextRandom
  disk <- findSDev rg
  let Just enc = findDiskEnclosure disk rg
  Just node <- return $ do
    e <- findDiskEnclosure disk rg
    listToMaybe $ do
       h :: Host <- G.connectedTo e Has rg
       G.connectedTo h Runs rg

  usend (_ts_rc ts) $ DriveFailed eid node (Slot enc 0) (aDiskSD disk)
  -- Need to ack the response to Mero

  forM_ (aDiskMero disk) $ \m0disk -> do
    Just{} <- waitState m0disk (_ts_mm ts) 2 10 (== M0.SDSFailed)
    return ()

  sayTest "Drive failed should be processed"
  _ :: DriveFailed <- expectPublished

  sayTest "SSPL should receive a command to power off the drive"
  do
    msg <- expectNodeMsg ssplTimeout
    sayTest $ "sspl_msg(poweroff): " ++ show msg
    let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString (DrivePowerdown . pack $ (\(StorageDevice sn) -> sn) $ aDiskSD disk)
    liftIO $ assertEqual "drive powerdown command is issued"  (Just cmd) msg

-- | Test that we respond correctly to a notification that a RAID device
--   has failed.
testMetadataDriveFailed :: (Typeable g, RGroup g)
                        => Transport -> Proxy g -> IO ()
testMetadataDriveFailed transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)

  someJoinedNode : _ <- return $ _ts_nodes ts
  Just hostname <- getHostName ts $ localNodeId someJoinedNode
  Just enc <- G.connectedFrom Has (Host hostname) <$> G.getGraph (_ts_mm ts)
  let sdev1 = ADisk (StorageDevice "mdserial1") Nothing "/dev/mddisk1" "md_no_wwn_1"
      sdev2 = ADisk (StorageDevice "mdserial2") Nothing "/dev/mddisk2" "md_no_wwn_2"

  sayTest "Announcing metadata drives through HPI"
  announceNewSDev enc sdev1 ts
  announceNewSDev enc sdev2 ts

  let raidDevice = "/dev/raid"
      raidData = mkResponseRaidData (pack hostname) raidDevice
                                    [ (("/dev/mddisk1", "mdserial1"), True) -- disk1 ok
                                    , (("/dev/mddisk2", "mdserial2"), False) -- disk2 failed
                                    ]
      message = LBS.toStrict $ encode
                               $ mkSensorResponse
                               $ emptySensorMessage {
                                  sensorResponseMessageSensor_response_typeRaid_data = Just raidData
                                }

  usend (_ts_rmq ts) $ MQBind "sspl_iem" "sspl_iem" "sspl_ll"
  usend (_ts_rmq ts) . MQSubscribe "sspl_iem" =<< getSelfPid

  subscribeOnTo [processNodeId $ _ts_rc ts]
    (Proxy :: Proxy (HAEvent (NodeId, SensorResponseMessageSensor_response_typeRaid_data)))

  usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" message


  sayTest "RAID message published"
  -- Expect the message to be processed by RC
  _ :: HAEvent (NodeId, SensorResponseMessageSensor_response_typeRaid_data) <- expectPublished

  do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    -- We should see a message to SSPL to remove the drive
    let nc = NodeRaidCmd raidDevice (RaidRemove "/dev/mddisk2")
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "drive removal command is issued" cmd msg
    void . promulgateEQ [processNodeId $ _ts_rc ts] $ CommandAck uid (Just nc) AckReplyPassed

  -- The RC should issue a 'ResetAttempt' and should be handled.
  sayTest "RAID removal for drive received at SSPL"
  _ :: HAEvent ResetAttempt <- expectPublished

  rg <- G.getGraph (_ts_mm ts)
  -- Look up the storage device by path
  let [sd]  = [ d |  e :: Enclosure <- maybeToList $ G.connectedFrom Has (Host hostname) rg
                  ,  s :: Slot <- G.connectedTo e Has rg
                  ,  d :: StorageDevice <- maybeToList $ G.connectedFrom Has s rg
                  , di <- G.connectedTo d Has rg
                  , di == DIPath "/dev/mddisk2"
                  ]

  let disk2 = ADisk {
      aDiskSD = sd
    , aDiskMero = Nothing
    , aDiskPath = "/dev/mddisk2"
    , aDiskWWN = error "WWN not initialised"
  }

  sayTest "ResetAttempt message published"
  -- We should see `ResetAttempt` from SSPL
  do
    msg <- expectNodeMsg ssplTimeout
    sayTest $ "sspl_msg(reset): " ++ show msg
    let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString (DriveReset "mdserial2")
    liftIO $ assertEqual "drive reset command is issued"  (Just cmd) msg

  sayTest "Reset command received at SSPL"
  resetComplete (_ts_rc ts) (_ts_mm ts) disk2 AckReplyPassed

  do
    msg <- expectNodeMsg ssplTimeout
    sayTest $ "sspl_msg(raid_add): " ++ show msg
    let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString (NodeRaidCmd raidDevice (RaidAdd "/dev/mddisk2"))
    liftIO $ assertEqual "Drive is added back to raid array" (Just cmd) msg

  sayTest "Raid_data message processed by RC"

type RaidMsg = (NodeId, SensorResponseMessageSensor_response_typeRaid_data)

testExpanderResetRAIDReassemble :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testExpanderResetRAIDReassemble transport pg = topts >>= \to -> run' transport pg [] to $ \ts -> do
  let rcNodeId = processNodeId $ _ts_rc ts
  subscribeOnTo [rcNodeId] (Proxy :: Proxy (HAEvent ExpanderReset))
  subscribeOnTo [rcNodeId] (Proxy :: Proxy (HAEvent RaidMsg))
  subscribeOnTo [rcNodeId] (Proxy :: Proxy StopProcessResult)
  subscribeOnTo [rcNodeId] (Proxy :: Proxy StartProcessesOnNodeResult)

  -- We need to send info about raid device with a host that is in the
  -- cluster info. Pick some random node using the test data. The
  -- alternative would be to pick one from RG.
  someJoinedNode : _ <- return $ _ts_nodes ts
  Just host <- getHostName ts $ localNodeId someJoinedNode
  Just enc' <- G.connectedFrom Has (Host host) <$> G.getGraph (_ts_mm ts)
  let sdev1 = ADisk (StorageDevice "mdserial1") Nothing "/dev/mddisk1" "md_no_wwn_1"
      sdev2 = ADisk (StorageDevice "mdserial2") Nothing "/dev/mddisk2" "md_no_wwn_2"

  sayTest "Announcing metadata drives through HPI"
  announceNewSDev enc' sdev1 ts
  announceNewSDev enc' sdev2 ts

  let raidDevice = "/dev/raid"
      raidData = mkResponseRaidData (pack host) raidDevice
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
  usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" raidMsg
  _ :: HAEvent RaidMsg <- expectPublished
  sayTest "RAID devices established"

  rg <- G.getGraph (_ts_mm ts)
  let encs = [ enc | rack <- G.connectedTo Cluster Has rg :: [Rack]
                   , enc <- G.connectedTo rack Has rg]

  sayTest $ "Enclosures: " ++ show encs
  let [enc] = encs
      (Just m0enc) = encToM0Enc enc rg

  sayTest $ "(enc, m0enc): " ++ show (enc, m0enc)

  -- First, we sent expander reset message for an enclosure.
  usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" erm

  -- Should get propogated to the RC
  _ :: HAEvent ExpanderReset <- expectPublished
  sayTest "ExpanderReset rule fired"

  -- Should expect notification from Mero that the enclosure is transient
  waitState m0enc (_ts_mm ts) 2 10 (== M0_NC_TRANSIENT) >>= \case
    Nothing -> fail "Enclosure didn't become transient"
    Just{} -> return ()

  -- Should also expect a message to SSPL asking it to disable swap
  _ <- do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    sayTest $ "sspl_msg(disable_swap): " ++ show msg
    let nc = SwapEnable False
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "Swap is disabled" cmd msg
    -- Reply with a command acknowledgement
    void . promulgateEQ [rcNodeId] $ CommandAck uid (Just nc) AckReplyPassed

  -- TODO: Maybe expander code should use StopProcessesOnNodeRequest
  -- or similar? Right now it just blindly tries to shut everything
  -- down.
  StopProcessResult{} <- expectPublished
  sayTest "Mero process stop finished"

  -- Should see unmount message
  _ <- do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    sayTest $ "sspl_msg(unmount): " ++ show msg
    let nc = (Unmount "/var/mero")
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "/var/mero is unmounted" cmd msg
    -- Reply with a command acknowledgement
    void . promulgateEQ [rcNodeId] $ CommandAck uid (Just nc) AckReplyPassed

  -- Should see 'stop RAID' message
  _ <- do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    sayTest $ "sspl_msg(stop_raid): " ++ show msg
    let nc = NodeRaidCmd raidDevice RaidStop
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "RAID is stopped" cmd msg
    -- Reply with a command acknowledgement
    void . promulgateEQ [rcNodeId] $ CommandAck uid (Just nc) AckReplyPassed

  -- Should see 'reassemble RAID' message
  _ <- do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    sayTest $ "sspl_msg(assemble_raid): " ++ show msg
    let nc = NodeRaidCmd "--scan" (RaidAssemble [])
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "RAID is assembling" cmd msg
    -- Reply with a command acknowledgement
    void . promulgateEQ [rcNodeId] $ CommandAck uid (Just nc) AckReplyPassed

  -- TODO: Expand to all processes we would expect
  NodeProcessesStarted{} <- expectPublished
  sayTest "Mero process start result sent"

  -- Should expect notification from Mero that the enclosure is transient
  waitState m0enc (_ts_mm ts) 2 10 (== M0_NC_ONLINE) >>= \case
    Nothing -> fail "Enclosure didn't become transient"
    Just{} -> return ()
  where
    topts = mkDefaultTestOptions <&> \tos ->
      tos { _to_cluster_setup = Bootstrapped }
