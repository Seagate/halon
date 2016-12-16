{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}
module HA.Castor.Story.Tests
  ( mkTests
  , run
  , run'
  , TestOptions(..)
  , TestSetup(..)
  , ClusterSetup(..)
  , mkDefaultTestOptions
  ) where

import           Control.Arrow ((&&&))
import           Control.Distributed.Process hiding (bracket)
import           Control.Distributed.Process.Node
import           Control.Exception as E hiding (assert)
import           Control.Lens hiding (to)
import           Control.Monad (foldM, forM_, replicateM_, void, when)
import           Data.Aeson (decode, encode)
import qualified Data.Aeson.Types as Aeson
import           Data.Binary (Binary)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import           Data.Defaultable
import           Data.Foldable (for_)
import           Data.Maybe (isJust, listToMaybe, mapMaybe)
import           Data.Proxy
import           Data.Text (pack)
import           Data.Typeable
import qualified Data.UUID as UUID
import           Data.UUID.V4 (nextRandom)
import           Data.Vinyl
import           GHC.Generics (Generic)
import qualified HA.EQTracker.Process as EQT
import           HA.Encode
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.Multimap
import           HA.NodeUp (nodeUp')
import           HA.RecoveryCoordinator.Actions.Mero (getNodeProcesses)
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.RecoveryCoordinator.Castor.Drive
import           HA.RecoveryCoordinator.Castor.Drive.Actions
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.Actions.Conf (encToM0Enc)
import           HA.RecoveryCoordinator.RC.Events.Cluster
import           HA.RecoveryCoordinator.RC.Subscription
import           HA.RecoveryCoordinator.Service.Events
import           HA.Replicator
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.SafeCopy
import qualified HA.Services.DecisionLog as DL
import           HA.Services.Mero
import qualified HA.Services.Mero.Mock as Mock
import           HA.Services.SSPL
import           HA.Services.SSPL.LL.Resources
import           HA.Services.SSPL.Rabbit
import           Helper.InitialData
import           Helper.SSPL
import           Mero.ConfC (Fid(..))
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.AMQP
import           Network.CEP
import           Network.Transport
import           RemoteTables (remoteTable)
import           SSPL.Bindings
import           Test.Framework
import           Test.Tasty.HUnit (Assertion, assertEqual, assertFailure)
import           TestRunner

myRemoteTable :: RemoteTable
myRemoteTable = TestRunner.__remoteTableDecl remoteTable

-- | Ask RC to put mock version of @halon:m0d@ service in RG.
-- Optionally set the cluster disposition to online.
data MockM0 = MockM0 ProcessId Bool
  deriving (Show, Eq, Generic, Typeable)
instance Binary MockM0

-- | Reply to 'MockM0'
data MockM0Reply = MockM0RequestOK NodeId
                 | MockM0RequestFailed String
  deriving (Generic, Typeable)
instance Binary MockM0Reply


-- | Ask RC to start a mock version of @halon:m0d@ service.
data PopulateMock = PopulateMock ProcessId NodeId
                  -- ^ PopulateMock @halon:m0d-worker-pid@ @target-node@
  deriving (Show, Eq, Ord, Generic, Typeable)

-- | Reply to 'MockM0'
data PopulateMockReply = MockRunning NodeId
                       | MockPopulateFailure NodeId String
  deriving (Show, Eq, Ord, Generic, Typeable)
instance Binary PopulateMockReply

ssplTimeout :: Int
ssplTimeout = 10*1000000

data ThatWhichWeCallADisk = ADisk {
    aDiskSD :: StorageDevice -- ^ Has a storage device
  , aDiskMero :: Maybe (M0.SDev) -- ^ Maybe has a corresponding Mero device
  , aDiskSN :: String -- ^ Has a serial number
  , aDiskPath :: String -- ^ Has a path
  , aDiskWWN :: String -- ^ Has a WWN
}

testRules :: Definitions RC ()
testRules = do
  defineSimple "start-mock-service" $ \msg@(MockM0 caller setOnlineCluster) -> do
    modifyGraph $ putM0d Mock.m0dMock
    when setOnlineCluster $ do
      modifyGraph $ G.connect Cluster Has M0.ONLINE
    liftProcess $ usend caller msg

  let jobPopulateMock :: Job PopulateMock PopulateMockReply
      jobPopulateMock = Job "populate-mock-service"

  mkJobRule jobPopulateMock args $ \(JobHandle getRequest finish) -> do
    process_map_set <- phaseHandle "process_map_set"
    mock_initialise_done <- phaseHandle "mock_initialise_done"
    mock_up <- phaseHandle "mock_up"
    mock_timed_out <- phaseHandle "mock_timed_out"

    let ourNode km _ l = return $ case (km, getField $ rget fldM0Node l) of
          (KernelStarted m0n, Just m0n') | m0n == m0n' -> Just km
          (KernelStartFailure m0n, Just m0n') | m0n == m0n' -> Just km
          _ -> Nothing
        cmdAck m _ l = return $ case (m, getField $ rget fldMockAck l) of
          (u :: Mock.MockCmdAck, Just u') | u == u' -> Just ()
          _ -> Nothing

        route (PopulateMock m0dPid nid) = do
          rg <- getLocalGraph
          case M0.nodeToM0Node (Node nid) rg of
            Nothing -> do
              return $ Right ( MockPopulateFailure nid $ "No M0.Node associated with " ++ show nid
                             , [finish] )
            Just m0n -> do
              let procs = getNodeProcesses (Node nid) rg
                  pmap = map (\p -> (p, G.connectedTo p M0.IsParentOf rg)) procs
              mack <- liftProcess $ Mock.sendMockCmd (Mock.SetProcessMap pmap) m0dPid
              modify Local $ rlens fldM0Node . rfield .~ Just m0n
              modify Local $ rlens fldMockAck . rfield .~ Just mack
              return $ Right ( MockPopulateFailure nid $ "default: " ++ show nid
                             , [process_map_set, timeout 10 mock_timed_out] )

    setPhaseIf process_map_set cmdAck $ \() -> do
      PopulateMock m0dPid _ <-  getRequest
      mack <- liftProcess $ Mock.sendMockCmd Mock.MockInitialiseFinished m0dPid
      modify Local $ rlens fldMockAck . rfield .~ Just mack
      switch [mock_initialise_done, timeout 10 mock_timed_out]

    setPhaseIf mock_initialise_done cmdAck $ \() -> do
      switch [mock_up, timeout 20 mock_timed_out]

    setPhaseIf mock_up ourNode $ \ks -> do
      PopulateMock _ nid <-  getRequest
      case ks of
        KernelStarted{} ->
          modify Local $ rlens fldRep . rfield .~ Just (MockRunning nid)
        KernelStartFailure{} -> modify Local $ rlens fldRep . rfield .~ Just
          (MockPopulateFailure nid $ "KernelStartFailure reported on " ++ show nid)
      continue finish

    directly mock_timed_out $ do
      PopulateMock _ nid <-  getRequest
      modify Local $ rlens fldRep . rfield .~ Just
        (MockPopulateFailure nid $ "Timed out waiting for mock on " ++ show nid)
      continue finish

    return route
    where
      fldReq = Proxy :: Proxy '("request", Maybe PopulateMock)
      fldRep = Proxy :: Proxy '("reply", Maybe PopulateMockReply)
      fldM0Node = Proxy :: Proxy '("m0node", Maybe M0.Node)
      fldMockAck = Proxy :: Proxy '("mock-ack", Maybe Mock.MockCmdAck)
      args = fldM0Node  =: Nothing
         <+> fldMockAck =: Nothing
         <+> fldReq     =: Nothing
         <+> fldRep     =: Nothing

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

data TestOptions = TestOptions
  { _to_initial_data :: CI.InitialData
  , _to_run_decision_log :: !Bool
  , _to_run_sspl :: !Bool
  , _to_cluster_setup :: !ClusterSetup
  } deriving (Eq, Show)

data TestSetup = TestSetup
  { _ts_rc :: ProcessId
  -- ^ RC 'ProcessId'
  , _ts_eq :: ProcessId
  -- ^ EQ 'ProcessId'
  , _ts_mm :: StoreChan
  -- ^ MM 'ProcessId'
  , _ts_rmq :: ProcessId
  -- ^ RMQ 'ProcessId'
  , _ts_nodes :: [LocalNode]
    -- ^ Group of nodes involved in the test
  }

-- | What should we ask the cluster to do before we run the tests.
data ClusterSetup =
  Bootstrapped
  -- ^ Cluster bootstrap will be ran and test will only start once
  -- cluster has reported to have bootstrapped successfully.
  | HalonM0DOnly
  -- ^ Start @halon:m0d@ services only.
  | NoSetup
  -- ^ Perform no actions.
  deriving (Show, Eq)

-- | Create some default 'TestOptions' for a test.
mkDefaultTestOptions :: IO TestOptions
mkDefaultTestOptions = do
  idata <- defaultInitialData
  return $ TestOptions
    { _to_initial_data = idata
    , _to_run_decision_log = False
    , _to_run_sspl = True
    , _to_cluster_setup = NoSetup -- HalonM0DOnly
    }

-- | Start satellite nodes. This is intended to be ran from tracking
-- station node.
startSatellites :: [NodeId] -- ^ EQ nodes
                -> [(LocalNode, String)] -- ^ @(node, hostname)@ pairs
                -> Process ()
startSatellites _ [] = sayTest "startSatellites called without any nodes."
startSatellites eqs ns = withSubscription eqs (Proxy :: Proxy NewNodeConnected) $ do
  eqtPid <- whereis EQT.name >>= \case
    Nothing -> fail "startSatellites does not have a registered EQT"
    Just pid -> return pid

  liftIO . for_ ns $ \(n, h) -> forkProcess n $ do
    register EQT.name eqtPid
    sayTest $ "Sending nodeUp for: " ++ show (h, localNodeId n)
    nodeUp' h eqs

  let loop [] = return ()
      loop waits = receiveWait
        [ matchIf (\(pubValue -> NewNodeConnected n) -> n `elem` waits)
                  (\(pubValue -> NewNodeConnected n) -> loop $ filter (/= n) waits) ]
      nodes = map (\(ln, _) -> Node $! localNodeId ln) ns
  sayTest $ "Waiting for following satellites: " ++ show nodes
  loop nodes
  sayTest "startSatellites finished."

-- | Get system hostname of the given 'NodeId' from RG.
getHostName :: TestSetup
            -> NodeId
            -> Process (Maybe String)
getHostName ts nid = do
  rg <- G.getGraph (_ts_mm ts)
  return $! case G.connectedFrom Runs (Node nid) rg of
    Just (Host hn) -> Just hn
    _ -> Nothing

-- | Version of 'run'' using 'mkDefaultTestOptions'.
run :: (Typeable g, RGroup g)
    => Transport
    -- ^ Network transport
    -> Proxy g
    -- ^ Replication group
    -> [Definitions RC ()]
    -- ^ Extra rules
    -> (TestSetup -> Process ())
    -- ^ Test itself
    -> Assertion
run t pg extraRules test' = do
  topts <- mkDefaultTestOptions
  run' t pg extraRules topts test'

run' :: (Typeable g, RGroup g)
     => Transport
     -- ^ Network transport
     -> Proxy g
     -- ^ Replication group
     -> [Definitions RC ()]
     -- ^ Extra rules
     -> TestOptions
     -- ^ TestConfiguration
     -> (TestSetup -> Process ())
     -- ^ Test itself
     -> Assertion
run' transport pg extraRules to test = do
  let idata = _to_initial_data to
      numNodes = length (CI.id_m0_servers idata)
  runTest (numNodes + 1) 20 15000000 transport myRemoteTable $ \lnodes -> do
    sayTest $ "Starting setup for a " ++ show numNodes ++ " node test."
    let lnWithHosts = zip lnodes $ map CI.m0h_fqdn (CI.id_m0_servers idata)
        nids = map localNodeId lnodes

    withTrackingStation pg (testRules:extraRules) $ \ta -> do
      let rcNodeId = processNodeId $ ta_rc ta
      link (ta_rc ta)
      -- Before we do much of anything, set a mock halon:m0d in the RG
      -- so that nothing tries to run the real deal.

      self <- getSelfPid

      -- Start satellites before initial data is loaded as otherwise
      -- RC rules will try to start processes on node automatically.
      -- We want a potential clean bootstrap.
      startSatellites [rcNodeId] lnWithHosts

      withSubscription [rcNodeId] (Proxy :: Proxy InitialDataLoaded) $ do
        _ <- promulgateEQ [rcNodeId] idata
        expectPublished >>= \case
          InitialDataLoaded -> return ()
          InitialDataLoadFailed e -> fail e

      when (_to_run_decision_log to) $ do
        _ <- serviceStartOnNodes [rcNodeId] DL.decisionLog
               (DL.processOutput self) nids (\_ _ -> return ())
        sayTest "Started decision log services."

      when (_to_run_sspl to) $ do
        withSubscription [rcNodeId] (Proxy :: Proxy (HAEvent DeclareChannels)) $ do
          void . serviceStartOnNodes [rcNodeId] sspl ssplConf nids $ \_ pid -> do
            -- Wait for DeclareChannels for each service.
            receiveWait
             [ matchIf (\(eventPayload . pubValue -> DeclareChannels pid' _) -> const True $ pid == pid')
                       (\_ -> return ()) ]
        sayTest "Started SSPL services."

      let startM0Ds = do
            -- We're starting the cluster but our halon:m0d mocks will
            -- sit there waiting for initialisation. Looking for the
            -- services that are coming up and when we see their
            -- worker process spawn, tell RC to initialise it and let
            -- us hear back.
            let loopDispatch [] = return ()
                loopDispatch waits = do
                  let act ws' nid = do
                        whereisRemoteAsync nid Mock.m0dMockWorkerLabel
                        WhereIsReply _ mt <- expect
                        case mt of
                          Nothing -> return ws'
                          Just m0dPid -> do
                            _ <- promulgateEQ [rcNodeId] $ PopulateMock m0dPid nid
                            return $! filter (/= nid) ws'
                  foldM act waits nids >>= \newWaits ->do
                    -- 200ms breather otherwise we really go to town on requests
                    _ <- receiveTimeout 200000 []
                    loopDispatch newWaits
            loopDispatch nids
            sayTest "Finished dispatching halon:m0d initialisers."
            -- Now that we asked RC to initialise everything, we just
            -- wait for the mock services to bootstrap and send
            -- relevant information back to RC and RC can send it back
            -- to us.
            let loopStarted [] = return ()
                loopStarted waits = receiveWait
                  [ matchIf (\case Published (MockPopulateFailure n _) _ ->
                                     n `elem` waits
                                   Published (MockRunning n) _ ->
                                     n `elem` waits)
                            (\case Published (MockPopulateFailure _ s) _ ->
                                     fail s
                                   Published (MockRunning n) _ ->
                                     loopStarted $ filter (/= n) waits) ]
            withSubscription [rcNodeId] (Proxy :: Proxy PopulateMockReply) $ do
              loopStarted nids
            sayTest "All halon:m0d mock instances populated."

      let mockMsg = MockM0 self (_to_cluster_setup to == HalonM0DOnly)
      usend (ta_rc ta) mockMsg
      receiveWait [ matchIf (\m -> m == mockMsg) (\_ -> return ()) ]
      sayTest "halon:m0d mock implanted in RG."

      case _to_cluster_setup to of
        Bootstrapped -> do
          withSubscription [rcNodeId] (Proxy :: Proxy ClusterStartResult) $ do
            _ <- promulgateEQ [rcNodeId] ClusterStartRequest
            startM0Ds
            expectPublished >>= \case
              ClusterStartOk -> sayTest "Cluster bootstrap finished."
              e -> fail $ "Cluster fail to bootstrap with: " ++ show e
        HalonM0DOnly -> do
          rg' <- G.getGraph (ta_mm ta)
          for_ (mapMaybe (\n -> M0.nodeToM0Node (Node n) rg') nids) $ \m0n -> do
            _ <- promulgateEQ [rcNodeId] $! StartHalonM0dRequest m0n
            sayTest $ "Sent StartHalonM0dRequest for " ++ show m0n
          startM0Ds
        NoSetup -> sayTest "No setup requested."

      -- TODO: We should only spawn this when SSPL is spawned.
      rmq <- spawnMockRabbitMQ self
      usend rmq $ MQSubscribe "halon_sspl" self
      usend rmq $ MQBind "halon_sspl" "halon_sspl" "sspl_ll"
      sayTest "Started mock RabbitMQ service."
      sayTest "Starting test..."

      test $ TestSetup
        { _ts_eq = ta_eq ta
        , _ts_mm = ta_mm ta
        , _ts_rc = ta_rc ta
        , _ts_rmq = rmq
        , _ts_nodes = lnodes }
      sayTest "Test finished! Cleaning..."

      when (_to_run_sspl to) $ do
        for_ nids $ \nid -> do
          void . promulgateEQ [rcNodeId] . encodeP $ ServiceStopRequest (Node nid) sspl
        void $ receiveTimeout 1000000 []
      unlink rmq
      kill rmq "end of game"
      sayTest "All done!"
  where
    ssplConf = SSPLConf
      (ConnectionConf (Configured "localhost")
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

    spawnMockRabbitMQ :: ProcessId -> Process ProcessId
    spawnMockRabbitMQ self = do
      pid <- spawnLocal $ do
        link self
        rabbitMQProxy $ ConnectionConf (Configured "localhost")
                                       (Configured "/")
                                       ("guest")
                                       ("guest")
      sayTest "Clearing RMQ queues."
      purgeRmqQueues pid [ "sspl_dcsque", "sspl_iem"
                         , "halon_sspl", "sspl_command_ack"]
      sayTest "RMQ queues purged."
      link pid
      return pid

-- | Waits until given object enters state.
waitState :: HasConfObjectState a
          => a                        -- ^ Object to examine
          -> StoreChan                -- ^ Where to retrieve current RG from.
          -> Int                      -- ^ Time between tries, seconds
          -> Int                      -- ^ Number of tries
          -> (StateCarrier a -> Bool) -- ^ Predicate on state
          -> Process (Maybe (StateCarrier a))
waitState _ _ _ tries _ | tries <= 0 = return Nothing
waitState obj mm interval tries p = do
  rg <- G.getGraph mm
  let st = HA.Resources.Mero.Note.getState obj rg
  if p st
  then return $ Just st
  else do
    _ <- receiveTimeout (interval * 1000000) []
    waitState obj mm interval (tries - 1) p

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

-- | Find 'Enclosure' that 'StorageDevice' ('aDiskSD') belongs to.
findDiskEnclosure :: ThatWhichWeCallADisk -> G.Graph -> Maybe Enclosure
findDiskEnclosure disk rg = G.connectedFrom Has (aDiskSD disk) rg

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

-- | Check if specified device have RemovedAt attribute.
checkStorageDeviceRemoved :: String -> Int -> G.Graph -> Bool
checkStorageDeviceRemoved enc idx rg = not . Prelude.null $
  [ () | dev  <- G.connectedTo (Enclosure enc) Has rg :: [StorageDevice]
       , any (==(DIIndexInEnclosure idx))
             (G.connectedTo dev Has rg :: [DeviceIdentifier])
       , any (==SDRemovedAt)
             (G.connectedTo dev Has rg :: [StorageDeviceAttr])
       ]

expectNodeMsg :: Int -> Process (Maybe ActuatorRequestMessageActuator_request_typeNode_controller)
expectNodeMsg = (fmap (fmap snd)) . expectNodeMsgUid

expectNodeMsgUid :: Int -> Process (Maybe (Maybe UUID, ActuatorRequestMessageActuator_request_typeNode_controller))
expectNodeMsgUid = expectActuatorMsg
  (actuatorRequestMessageActuator_request_typeNode_controller
  . actuatorRequestMessageActuator_request_type
  . actuatorRequestMessage
  )

expectLoggingMsg :: Int -> Process (Maybe (Either String ActuatorRequestMessageActuator_request_typeLogging))
expectLoggingMsg = expectActuatorMsg'
  ( actuatorRequestMessageActuator_request_typeLogging
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

expectActuatorMsg' :: (ActuatorRequest -> Maybe b) -> Int -> Process (Maybe (Either String b))
expectActuatorMsg' f t = expectTimeout t >>= return . \case
  Just (MQMessage _ msg) -> Just $ case f =<< (decode . LBS.fromStrict $ msg) of
       Nothing -> Left (BS8.unpack msg)
       Just x  -> Right x
  Nothing -> Nothing

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
failDrive _ (ADisk _ Nothing _ _ _) = error "Cannot fail a non-Mero disk."
failDrive ts (ADisk _ (Just sdev) serial _ _) = do
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
resetComplete rc mm adisk@(ADisk stord m0sdev serial _ _) success = do
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
    h :: Host <- G.connectedFrom Has (aDiskSD adisk) rg
    listToMaybe $ G.connectedTo h Runs rg

  _ <- usend rc $ DriveOK uuid node enc stord
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

-- | SSPL emits EMPTY_None event for one of the drives.
testDriveRemovedBySSPL :: (Typeable g, RGroup g)
                       => Transport -> Proxy g -> IO ()
testDriveRemovedBySSPL transport pg = run transport pg [] $ \ts -> do
  subscribeOnTo [processNodeId $ _ts_rc ts] (Proxy :: Proxy DriveRemoved)
  rg <- G.getGraph (_ts_mm ts)
  sdev <- findSDev rg
  let Just (Enclosure enclosureName) = findDiskEnclosure sdev rg

  -- Find the host on which this device is actually on
  Just (Host host) <- return $ do
    d :: M0.Disk <- G.connectedFrom M0.At (aDiskSD sdev) rg
    c :: M0.Controller <- G.connectedFrom M0.IsParentOf d rg
    G.connectedTo c M0.At rg

  let devIdx    = 1
      message0 = LBS.toStrict . encode . mkSensorResponse $ mkResponseHPI
                  (pack host) (pack enclosureName)
                  (pack $ aDiskSN sdev)
                  (fromIntegral devIdx)
                  (pack $ aDiskPath sdev)
                  (pack $ aDiskWWN sdev)
                  False True
      message = LBS.toStrict $ encode $ mkSensorResponse
         $ emptySensorMessage
            { sensorResponseMessageSensor_response_typeDisk_status_drivemanager =
              Just $ mkResponseDriveManager (pack enclosureName)
                                            (pack $ aDiskSN sdev)
                                            devIdx "EMPTY" "None"
                                            (pack $ aDiskPath sdev) }
  usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" message0
  usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" message
  Just{} <- expectTimeout ssplTimeout :: Process (Maybe (Published DriveRemoved))
  _ <- receiveTimeout 1000000 []
  sayTest "Check drive removed"
  True <- checkStorageDeviceRemoved enclosureName devIdx <$> G.getGraph (_ts_mm ts)

  -- XXX: dirty hack: deviceDetach call in mkDetachDisk can't
  -- complete (or even begin) without m0worker. To arrange a mero
  -- worker, we need a better test that also sets up (and tears
  -- down) env than this one here. To temporarily unblock this test,
  -- we "pretend" that the detach went OK by sending the message
  -- that mkDetachDisk would send on successful detach: this is the
  -- message the rule is waiting for.
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
    h :: Host <- G.connectedFrom Has (aDiskSD disk) rg
    listToMaybe $ G.connectedTo h Runs rg

  usend (_ts_rc ts) $ DriveFailed eid node enc (aDiskSD disk)
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
              $ nodeCmdString (DrivePowerdown . pack $ aDiskSN disk)
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
  _ <- expect :: Process (Published (HAEvent (NodeId, SensorResponseMessageSensor_response_typeRaid_data)))

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
  let [sd]  = [ d |  d <- G.connectedTo (Host hostname) Has rg
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

-- | Message used in 'testGreeting'
newtype MarkDriveFailed = MarkDriveFailed ProcessId
  deriving (Generic, Typeable, Binary)

testGreeting :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testGreeting transport pg = run transport pg [rule] $ \ts -> do
  self <- getSelfPid
  _ <- usend (_ts_rc ts) $ MarkDriveFailed self
  MarkDriveFailed{} <- expect

  let
    message = LBS.toStrict $ encode
                             $ mkActuatorResponse
                             $ emptyActuatorMessage {
                                actuatorResponseMessageActuator_response_typeThread_controller = Just $
                                  ActuatorResponseMessageActuator_response_typeThread_controller
                                    "ThreadController"
                                    "SSPL-LL service has started successfully"
                               }
  usend (_ts_rmq ts) $ MQPublish "sspl_halon" "sspl_ll" message
  mmsg1 <- expectNodeMsg ssplTimeout
  case mmsg1 of
    Just _s  -> return () -- XXX: uids are not deterministic
    Nothing -> liftIO $ assertFailure "node cmd was not received"
  Just mmsg2 <- expectLoggingMsg ssplTimeout
  case mmsg2 of
    Left s  -> liftIO $ assertFailure $ "wrong message received" ++ s
    Right _  -> return ()
  where
    rule = defineSimple "mark-disk-failed" $ \msg@(MarkDriveFailed caller) -> do
      rg <- getLocalGraph
      case G.getResourcesOfType rg of
        sd : _ -> updateDriveStatus sd "HALON-FAILED" "MERO-Timeout"
        [] -> return ()
      liftProcess $ usend caller msg


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
  _ <- expect :: Process (Published (HAEvent RaidMsg))
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
  StopProcessResult _ <- expectPublished
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
  NodeProcessesStarted _ <- expectPublished
  sayTest "Mero process start result sent"

  -- Should expect notification from Mero that the enclosure is transient
  waitState m0enc (_ts_mm ts) 2 10 (== M0_NC_ONLINE) >>= \case
    Nothing -> fail "Enclosure didn't become transient"
    Just{} -> return ()
  where
    topts = mkDefaultTestOptions <&> \tos ->
      tos { _to_cluster_setup = Bootstrapped }


deriveSafeCopy 0 'base ''PopulateMock
