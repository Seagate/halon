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
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero.Actions.Conf (encToM0Enc)
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import           HA.RecoveryCoordinator.RC.Actions.Core (getGraph)
import           HA.RecoveryCoordinator.RC.Subscription
import           HA.Replicator
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Runs(..))
import qualified HA.Resources as R (Node(..))
import qualified HA.Resources.Castor as Cas
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Service (getInterface)
import           HA.Service.Interface
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
  { aDiskSD :: Cas.StorageDevice -- ^ Has a storage device
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
        , testSuccess "Repaired drive goes back to repaired after reset" $
          testRepairedDriveReset transport pg
        , testSuccess "Rebalancing drive goes back to rebalance after reset" $
          testRebalanceDriveReset transport pg
        ]

-- | Get system hostname of the given 'NodeId' from RG.
getHostName :: TestSetup
            -> NodeId
            -> Process (Maybe String)
getHostName ts nid = do
  rg <- G.getGraph (_ts_mm ts)
  return $! case G.connectedFrom Runs (R.Node nid) rg of
    Just (Cas.Host hn) -> Just hn
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
               -> (G.Graph -> Process (Maybe a)) -- ^ Predicate on the graph.
               -> Process (Maybe a)
waitUntilGraph _ _ tries _ | tries <= 0 = return Nothing
waitUntilGraph mm interval tries p = do
  rg <- G.getGraph mm
  p rg >>= \case
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
  in if p st then return $ Just st else do
    sayTest $ "waitState: st=" ++ show st
    return Nothing

-- | Construct a 'ThatWhichWeCallADisk' per every 'M0.SDev' found in
-- RG.
findSDevs :: G.Graph -> [ThatWhichWeCallADisk]
findSDevs rg =
  [ ADisk storage (Just sdev) path wwn
  | sdev <- G.getResourcesOfType rg :: [M0.SDev]
  , Just (disk :: M0.Disk) <- [G.connectedTo sdev M0.IsOnHardware rg]
  , Just (storage :: Cas.StorageDevice) <- [G.connectedTo disk M0.At rg]
  , path <- return "path" -- Cas.DIPath path <- G.connectedTo storage Has rg
  , Cas.DIWWN wwn <- G.connectedTo storage Has rg
  ]

-- | Find some random 'ThatWhichWeCallADisk' in the RG.
findSDev :: G.Graph -> Process ThatWhichWeCallADisk
findSDev rg = case findSDevs rg of
  dv : _ -> return dv
  _ -> do
    _ <- liftIO $ assertFailure "Can't find a M0.SDev or its serial number"
    error "Unreachable"

-- | Find 'Enclosure' that 'StorageDevice' ('aDiskSD') belongs to.
findDiskEnclosure :: ThatWhichWeCallADisk -> G.Graph -> Maybe Cas.Enclosure
findDiskEnclosure disk rg = Cas.slotEnclosure <$> G.connectedTo (aDiskSD disk) Has rg

find2SDev :: G.Graph -> Process ThatWhichWeCallADisk
find2SDev rg =
  let dvs = [ ADisk storage (Just sdev) path wwn
            | sdev <- G.getResourcesOfType rg :: [M0.SDev]
            , Just (disk :: M0.Disk) <- [G.connectedTo sdev M0.IsOnHardware rg]
            , Just (storage :: Cas.StorageDevice) <- [G.connectedTo disk M0.At rg]
            , Cas.DIPath path <- G.connectedTo storage Has rg
            , Cas.DIWWN wwn <- G.connectedTo storage Has rg
            ]
  in case dvs of
    _:dv:_ -> return dv
    _    -> do
      _ <- liftIO $ assertFailure "Can't find a second M0.SDev or its serial number"
      error "Unreachable"

-- | Check if specified device have RemovedAt attribute.
checkStorageDeviceRemoved :: Cas.Enclosure -> Int -> G.Graph -> Bool
checkStorageDeviceRemoved enc idx rg = Prelude.null $
  [ () | slot@(Cas.Slot enc' idx') <- G.connectedTo enc Has rg
       , Just{} <- [G.connectedFrom Has slot rg :: Maybe Cas.StorageDevice]
       , enc == enc' && idx == idx'
       ]

-- | Announce a new 'StorageDevice' (through 'ThatWhichWeCallADisk')
-- to the RC through an HPI message. This is useful when the disk is
-- not in the initial data to begin with such as in the case of
-- metadata/RAID drives.
announceNewSDev :: Cas.Enclosure -> ThatWhichWeCallADisk -> TestSetup -> Process ()
announceNewSDev enc@(Cas.Enclosure enclosureName) sdev ts = do
  rg <- G.getGraph (_ts_mm ts)
  let Cas.Host host : _ = G.connectedTo enc Has rg
      devIdx = succ . maximum . map Cas.slotIndex $ G.connectedTo enc Has rg
      slot = Cas.Slot enc devIdx
      message = LBS.toStrict . encode . mkSensorResponse $ mkResponseHPI
        (pack host) (pack enclosureName)
        ((\(Cas.StorageDevice sn) -> pack sn) $ aDiskSD sdev) (fromIntegral devIdx)
        (pack $ aDiskPath sdev)
        (pack $ aDiskWWN sdev)
        True True
  withSubscription [processNodeId $ _ts_rc ts] (Proxy :: Proxy DriveInserted) $ do
    _rmq_publishSensorMsg (_ts_rmq ts) message
    let isOurDI (DriveInserted _ _ slot' sdev' (Just True)) = slot' == slot && sdev' == aDiskSD sdev
        isOurDI _ = False
    sayTest $ "Waiting for published " ++ show (slot, aDiskSD sdev)
    r <- receiveTimeout 10000000
      [ matchIf (\(Published v _) -> isOurDI v) (\_ -> return ()) ]
    case r of
      Nothing -> fail "announceNewSDev: timed out waiting for DriveInserted"
      Just{} -> return ()
  Just{} <- waitUntilGraph (_ts_mm ts) 1 10 $ \rg' ->
    -- Check that the drive is reachable from the enclosure, through
    -- the slot.
    let devs = [ d | slot'@Cas.Slot{} <- G.connectedTo enc Has rg'
                   , d <- maybeToList $ G.connectedFrom Has slot' rg' ]
    in return $! if aDiskSD sdev `elem` devs then Just () else Nothing
  return ()

-- | Listen for specified messages. Returns any messages we expected
-- but didn't received before a timeout occured.
expectNodeMsgCommands :: String -- ^ Caller identifier, for easy debugging
                      -> [ActuatorRequestMessageActuator_request_typeNode_controller]
                      -- ^ Messages we're expecting
                      -> Int -- ^ Timeout between messages in microseconds
                      -> Process [ActuatorRequestMessageActuator_request_typeNode_controller]
expectNodeMsgCommands _ [] _ = return []
expectNodeMsgCommands cname msgs t = expectNodeMsg t >>= \case
  Nothing -> return msgs
  Just m | m `elem` msgs -> expectNodeMsgCommands cname (filter (/= m) msgs) t
         | otherwise -> fail $ cname ++ " received unexpected message: " ++ show m

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
      , _hm_epoch = 0
      }

-- | Fail a drive (via Mero notification)
failDrive :: TestSetup -> ThatWhichWeCallADisk -> Process ()
failDrive _ (ADisk _ Nothing _ _) = error "Cannot fail a non-Mero disk."
failDrive ts (ADisk (Cas.StorageDevice serial) (Just sdev) _ _) = do
  let tserial = pack serial
  sayTest "failDrive"
  preResetSt <- HA.Resources.Mero.Note.getState sdev <$> G.getGraph (_ts_mm ts)
  -- We a drive failure note to the RC.
  promulgateEQ_ [processNodeId $ _ts_rc ts] (mkSDevFailedMsg sdev)

  -- Mero should be notified that the drive should be transient.
  Just{} <- waitState sdev (_ts_mm ts) 2 10 $ \st ->
    case TrI.runTransition Tr.sdevFailTransient preResetSt of
      TrI.NoTransition -> True
      TrI.TransitionTo st' -> st == st'
      TrI.InvalidTransition mkErr -> error $ "failDrive: " ++ mkErr sdev
  sayTest "failDrive: Drive transitioned"
  -- The RC should issue a 'ResetAttempt' and should be handled.
  _ :: HAEvent ResetAttempt <- expectPublished
  -- We should see `DriveReset` and LED set messages go out to SSPL
  let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
          $ nodeCmdString (DriveReset tserial)
  expectNodeMsgCommands "failDrive" [cmd] ssplTimeout >>= \case
    [] -> return ()
    ms -> fail $ "failDrive: SSPL wasn't sent " ++ show ms
  sayTest "failDrive: OK"

resetComplete :: ProcessId -- ^ RC
              -> StoreChan -- ^ MM
              -> ThatWhichWeCallADisk -- ^ Disk thing we're working on
              -> AckReply -- ^ Smart result
              -> M0.SDevState -- ^ State of the device after smart completes.
              -> Process ()
resetComplete rc mm adisk@(ADisk stord@(Cas.StorageDevice serial) m0sdev _ _) success expSt = do
  let tserial = pack serial
      resetCmd = CommandAck Nothing (Just $ DriveReset tserial) AckReplyPassed
      smartComplete = CommandAck Nothing (Just $ SmartTest tserial) success
  sayTest "resetComplete"
  -- Send 'SpielDeviceDetached' to the RC
  forM_ m0sdev $ \sd -> usend rc $ SpielDeviceDetached sd (Right ())
  -- Send 'DriveOK'
  uuid <- liftIO nextRandom
  rg <- G.getGraph mm
  Just (node, slot) <- return $ do
    slot <- G.connectedTo (aDiskSD adisk) Has rg
    n <- listToMaybe $ do
      h :: Cas.Host <- G.connectedTo (Cas.slotEnclosure slot) Has rg
      G.connectedTo h Runs rg
    return (n, slot)

  _ <- usend rc $ DriveOK uuid node slot stord
  sendRC (getInterface sspl) $ CAck resetCmd
  let smartTestRequest = ActuatorRequestMessageActuator_request_typeNode_controller
                       $ nodeCmdString (SmartTest tserial)
  sayTest "Waiting for SMART request."
  liftIO . assertEqual "RC requested smart test." (Just smartTestRequest)
              =<< expectNodeMsg ssplTimeout
  sayTest $ "Sending SMART completion message: " ++ show smartComplete
  -- Confirms that the disk powerdown operation has occured.
  _ <- sendRC (getInterface sspl) $ CAck smartComplete

  -- If the sdev is there
  forM_ m0sdev $ \sdev -> do
    -- Send 'SpielDeviceAttached' to the RC
    usend rc $ SpielDeviceAttached sdev (Right ())

    -- Wait for reset job to finish. Check we have a reply for the
    -- right device then check it's the expected reply.
    _ <- expectPublishedIf $ \case
      ResetSuccess stord' -> stord == stord' && success == AckReplyPassed
      ResetAborted _ -> False
      ResetFailure stord' -> stord == stord' && success /= AckReplyPassed

    Just{} <- waitState sdev mm 2 10 (== expSt)
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
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyPassed M0.SDSOnline

testHitResetLimit :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testHitResetLimit transport pg = do
  opts <- reduceTransientTimeout <$> mkDefaultTestOptions
  run' transport pg [] opts $ \ts -> do
    subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
    subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
    sdev <- G.getGraph (_ts_mm ts) >>= findSDev
    let resetAttemptThreshold = _hv_drive_reset_max_retries defaultHalonVars
        isTransient (M0.SDSTransient _) = True
        isTransient _ = False
    replicateM_ (resetAttemptThreshold + 1) $ do
      sayTest "============== FAILURE START ================================"
      failDrive ts sdev
      resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyPassed M0.SDSOnline
      sayTest "============== FAILURE Finish ================================"

    forM_ (aDiskMero sdev) $ \m0sdev -> do
      -- Fail the drive one more time
      void . promulgateEQ [processNodeId $ _ts_rc ts] $ mkSDevFailedMsg m0sdev
      -- Drive should go transient and then failed
      Just {} <- waitState m0sdev (_ts_mm ts) 2 10 isTransient
      Just M0.SDSFailed <- waitState m0sdev (_ts_mm ts) 2 10 (== M0.SDSFailed)
      return ()
  where
    reduceTransientTimeout opts' = opts' {
      _to_modify_halon_vars = \vars -> vars {
          -- Set a low transient drive timeout to ensure we go to FAILED state
          _hv_drive_transient_timeout = 2
        }
      }

testFailedSMART :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailedSMART transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
  sdev <- G.getGraph (_ts_mm ts) >>= findSDev
  failDrive ts sdev
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyFailed M0.SDSFailed

testSecondReset :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testSecondReset transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
  sdev <- G.getGraph (_ts_mm ts) >>= findSDev
  sdev2 <- G.getGraph (_ts_mm ts) >>= find2SDev
  failDrive ts sdev
  failDrive ts sdev2
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev2 AckReplyPassed M0.SDSOnline
  resetComplete (_ts_rc ts) (_ts_mm ts) sdev AckReplyPassed M0.SDSOnline

-- | Test that when a message about a drive marked as not installed
-- arrives to SSPL, the drive is removed from the slot and eventually
-- becomes transient.
testDriveRemovedBySSPL :: (Typeable g, RGroup g)
                       => Transport -> Proxy g -> IO ()
testDriveRemovedBySSPL transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy DriveRemoved)
  rg <- G.getGraph (_ts_mm ts)
  sdev <- findSDev rg
  let Just enc@(Cas.Enclosure enclosureName) = findDiskEnclosure sdev rg

  -- Find the host on which this device is actually on
  Just (Cas.Host host) <- return $ do
    d :: M0.Disk <- G.connectedFrom M0.At (aDiskSD sdev) rg
    c :: M0.Controller <- G.connectedFrom M0.IsParentOf d rg
    G.connectedTo c M0.At rg

  let Just (Cas.Slot _ devIdx) = aDiskMero sdev >>= \sd -> G.connectedTo sd M0.At rg
      message = LBS.toStrict . encode . mkSensorResponse $ mkResponseHPI
                  (pack host) (pack enclosureName)
                  (pack $ (\(Cas.StorageDevice sn) -> sn) $ aDiskSD sdev)
                  (fromIntegral devIdx)
                  (pack $ aDiskPath sdev)
                  (pack $ aDiskWWN sdev)
                  False True
  -- For now the device is still in the slot.
  False <- checkStorageDeviceRemoved enc devIdx <$> G.getGraph (_ts_mm ts)
  _rmq_publishSensorMsg (_ts_rmq ts) message
  Just{} <- expectTimeout ssplTimeout :: Process (Maybe (Published DriveRemoved))

  -- Wait until drive gets removed from the slot.
  Just{} <- waitUntilGraph (_ts_mm ts) 1 10 $ \rg' ->
    let devs = [ d | slot'@Cas.Slot{} <- G.connectedTo enc Has rg'
                   , d <- maybeToList $ G.connectedFrom Has slot' rg' ]
    in return $! if aDiskSD sdev `notElem` devs then Just () else Nothing

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
  eid <- liftIO nextRandom
  disk <- findSDev rg
  Just (node, slot) <- return $ do
    slot <- G.connectedTo (aDiskSD disk) Has rg
    n <- listToMaybe $ do
      h :: Cas.Host <- G.connectedTo (Cas.slotEnclosure slot) Has rg
      G.connectedTo h Runs rg
    return (n, slot)
  usend (_ts_rc ts) $ DriveFailed eid node slot (aDiskSD disk)

  forM_ (aDiskMero disk) $ \m0disk -> do
    Just{} <- waitState m0disk (_ts_mm ts) 2 10 (== M0.SDSFailed)
    return ()

  sayTest "Drive failed should be processed"
  _ :: DriveFailed <- expectPublished

  sayTest "SSPL should receive a command to power off the drive"
  do
    let sn = pack $ (\(Cas.StorageDevice sn') -> sn') (aDiskSD disk)
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString (DrivePowerdown sn)
        cmd1 = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString (DriveLed sn FaultOn)

    [] <- expectNodeMsgCommands "testDrivePoweredDown" [cmd, cmd1] ssplTimeout
    return ()

-- | Make a test that sets the drive to some starting state,
-- succesfully resets it and checks that the drive is in given state
-- after reset.
mkTestAroundReset :: (Typeable g, RGroup g)
                  => Transport -> Proxy g
                  -> M0.SDevState -- ^ Starting and stopping state for the drive
                  -> IO ()
mkTestAroundReset transport pg devSt = run transport pg [setupRule] $ \ts -> do
  getSelfPid >>= usend (_ts_rc ts) . RuleHook
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)
  sayTest "Waiting for SDev from RC."
  expect >>= \case
    Nothing -> fail "No SDev found in RG."
    Just (sdev :: M0.SDev) -> do
      sayTest $ "Waiting for SDev to become " ++ show devSt
      Just{} <- waitState sdev (_ts_mm ts) 2 10 $ \case
        st -> devSt == st
      let getOurDisk = filter (\ad -> aDiskMero ad == Just sdev)
      sayTest "Obtaining disk."
      adisk <- G.getGraph (_ts_mm ts) >>= \rg -> case getOurDisk $ findSDevs rg of
        adisk : _ -> return adisk
        _ -> fail "No ThatWhichWeCallADisk found for SDev."
      -- Consume LED FaultOn message caused by the state change.
      let sn = (\(Cas.StorageDevice sn') -> pack sn') (aDiskSD adisk)
          cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString (DriveLed sn FaultOn)
      [] <- expectNodeMsgCommands "mkTestAroundReset" [cmd] ssplTimeout
      failDrive ts adisk
      resetComplete (_ts_rc ts) (_ts_mm ts) adisk AckReplyPassed devSt
  where
    setupRule = define "mkTestAroundReset-setup" $ do
      rule_init <- phaseHandle "rule_init"
      setPhase rule_init $ \(RuleHook caller) -> do
        rg <- getGraph
        -- Find a single SDev
        let msdev = listToMaybe
              [ sdev
              | site :: Cas.Site <- G.connectedTo Cluster Has rg
              , rack :: Cas.Rack <- G.connectedTo site Has rg
              , encl :: Cas.Enclosure <- G.connectedTo rack Has rg
              , slot :: Cas.Slot <- G.connectedTo encl Has rg
              , sdev :: M0.SDev <- maybeToList $ G.connectedFrom M0.At slot rg
              ]
        case msdev of
          Nothing -> liftProcess $ usend caller (Nothing :: Maybe M0.SDev)
          Just sdev -> do
            _ <- applyStateChanges [stateSet sdev $ TrI.constTransition devSt]
            liftProcess . usend caller $ Just sdev
      start rule_init ()

-- | Test that a drive that is in repaired state ends up in repaired
-- state after it is reset.
testRepairedDriveReset :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testRepairedDriveReset t pg = mkTestAroundReset t pg M0.SDSRepaired

-- | Test that a drive that is in rebalancing state ends up in
-- rebalancing state after it is reset.
testRebalanceDriveReset :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testRebalanceDriveReset t pg = mkTestAroundReset t pg M0.SDSRebalancing

type RaidMsg = (UUID, NodeId, SensorResponseMessageSensor_response_typeRaid_data)

-- | Test that we respond correctly to a notification that a RAID device
--   has failed.
testMetadataDriveFailed :: (Typeable g, RGroup g)
                        => Transport -> Proxy g -> IO ()
testMetadataDriveFailed transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy (HAEvent ResetAttempt))
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy ResetAttemptResult)

  someJoinedNode : _ <- return $ _ts_nodes ts
  Just hostname <- getHostName ts $ localNodeId someJoinedNode
  Just enc <- G.connectedFrom Has (Cas.Host hostname) <$> G.getGraph (_ts_mm ts)
  let sdev1 = ADisk (Cas.StorageDevice "mdserial1") Nothing "/dev/mddisk1" "md_no_wwn_1"
      sdev2 = ADisk (Cas.StorageDevice "mdserial2") Nothing "/dev/mddisk2" "md_no_wwn_2"

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

  subscribeOnTo [processNodeId $ _ts_rc ts]
    (Proxy :: Proxy RaidMsg)

  _rmq_publishSensorMsg (_ts_rmq ts) message


  sayTest "RAID message published"
  -- Expect the message to be processed by RC
  _ :: RaidMsg <- expectPublished

  do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    -- We should see a message to SSPL to remove the drive
    let nc = NodeRaidCmd raidDevice (RaidRemove "/dev/mddisk2")
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "drive removal command is issued" cmd msg
    sendRC (getInterface sspl) . CAck $
      CommandAck uid (Just nc) AckReplyPassed
  -- The RC should issue a 'ResetAttempt' and should be handled.
  sayTest "RAID removal for drive received at SSPL"
  _ :: HAEvent ResetAttempt <- expectPublished

  rg <- G.getGraph (_ts_mm ts)
  -- Look up the storage device by path
  let [sd]  = [ d |  e :: Cas.Enclosure <- maybeToList $ G.connectedFrom Has (Cas.Host hostname) rg
                  ,  s :: Cas.Slot <- G.connectedTo e Has rg
                  ,  d :: Cas.StorageDevice <- maybeToList $ G.connectedFrom Has s rg
                  , di <- G.connectedTo d Has rg
                  , di == Cas.DIPath "/dev/mddisk2"
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
    liftIO $ assertEqual "drive reset command is issued" (Just cmd) msg

  sayTest "Reset command received at SSPL"
  resetComplete (_ts_rc ts) (_ts_mm ts) disk2 AckReplyPassed M0.SDSOnline

  do
    let cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString (NodeRaidCmd raidDevice (RaidAdd "/dev/mddisk2"))
    [] <- expectNodeMsgCommands "testMetadataDriveFailed" [cmd] ssplTimeout
    return ()
  sayTest "Raid_data message processed by RC"

testExpanderResetRAIDReassemble :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testExpanderResetRAIDReassemble transport pg = topts >>= \to -> run' transport pg [] to $ \ts -> do
  let rcNodeId = processNodeId $ _ts_rc ts
  subscribeOnTo [rcNodeId] (Proxy :: Proxy (HAEvent ExpanderReset))
  subscribeOnTo [rcNodeId] (Proxy :: Proxy RaidMsg)
  subscribeOnTo [rcNodeId] (Proxy :: Proxy MaintenanceStopNodeResult)
  subscribeOnTo [rcNodeId] (Proxy :: Proxy StartProcessesOnNodeResult)

  -- We need to send info about raid device with a host that is in the
  -- cluster info. Pick some random node using the test data. The
  -- alternative would be to pick one from RG.
  someJoinedNode : _ <- return $ _ts_nodes ts
  Just host <- getHostName ts $ localNodeId someJoinedNode
  Just enc' <- G.connectedFrom Has (Cas.Host host) <$> G.getGraph (_ts_mm ts)
  let sdev1 = ADisk (Cas.StorageDevice "mdserial1") Nothing "/dev/mddisk1" "md_no_wwn_1"
      sdev2 = ADisk (Cas.StorageDevice "mdserial2") Nothing "/dev/mddisk2" "md_no_wwn_2"

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
  _rmq_publishSensorMsg (_ts_rmq ts) raidMsg
  _ :: RaidMsg <- expectPublished
  sayTest "RAID devices established"

  rg <- G.getGraph (_ts_mm ts)
  let encls = [ encl
              | site :: Cas.Site <- G.connectedTo Cluster Has rg
              , rack :: Cas.Rack <- G.connectedTo site Has rg
              , encl <- G.connectedTo rack Has rg
              ]
  sayTest $ "Enclosures: " ++ show encls
  let [enc] = encls
      Just m0enc = encToM0Enc enc rg

  sayTest $ "(enc, m0enc): " ++ show (enc, m0enc)

  -- First, we sent expander reset message for an enclosure.
  _rmq_publishSensorMsg (_ts_rmq ts) erm

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
    sendRC (getInterface sspl) . CAck $
      CommandAck uid (Just nc) AckReplyPassed

  MaintenanceStopNodeOk{} <- expectPublished
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
    sendRC (getInterface sspl) . CAck $
      CommandAck uid (Just nc) AckReplyPassed

  -- Should see 'stop RAID' message
  _ <- do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    sayTest $ "sspl_msg(stop_raid): " ++ show msg
    let nc = NodeRaidCmd raidDevice RaidStop
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "RAID is stopped" cmd msg
    -- Reply with a command acknowledgement
    sendRC (getInterface sspl) . CAck $
      CommandAck uid (Just nc) AckReplyPassed

  -- Should see 'reassemble RAID' message
  _ <- do
    Just (uid, msg) <- expectNodeMsgUid ssplTimeout
    sayTest $ "sspl_msg(assemble_raid): " ++ show msg
    let nc = NodeRaidCmd "--scan" (RaidAssemble [])
        cmd = ActuatorRequestMessageActuator_request_typeNode_controller
              $ nodeCmdString nc
    liftIO $ assertEqual "RAID is assembling" cmd msg
    -- Reply with a command acknowledgement
    sendRC (getInterface sspl) . CAck $
      CommandAck uid (Just nc) AckReplyPassed

  NodeProcessesStarted{} <- expectPublished
  sayTest "Mero process start result sent"

  -- Should expect notification from Mero that the enclosure is transient
  waitState m0enc (_ts_mm ts) 2 10 (== M0_NC_ONLINE) >>= \case
    Nothing -> fail "Enclosure didn't become transient"
    Just{} -> return ()
  where
    topts = mkDefaultTestOptions <&> \tos ->
      tos { _to_cluster_setup = Bootstrapped }
