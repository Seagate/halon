{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE StrictData                #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE ViewPatterns              #-}
-- |
-- Module    : Helper.Runner
-- Copyright : (C) 2016-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Configurable test runner providing the environment requested by the
-- tests.
module Helper.Runner
  ( ClusterSetup(..)
  , RuleHook(..)
  , TestOptions(..)
  , TestSetup(..)
  , RmqSetup(..)
  , mkDefaultTestOptions
  , run
  , run'
  ) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Distributed.Process.Node
import           Control.Lens hiding (to)
import           Control.Monad (foldM, void, when)
import           Data.Binary (Binary)
import           Data.ByteString (ByteString)
import           Data.Defaultable (Defaultable(Configured))
import           Data.Foldable (for_)
import           Data.Maybe (mapMaybe)
import           Data.Proxy
import qualified Data.Text as T
import           Data.Typeable
import           Data.Vinyl
import           GHC.Generics (Generic)
import           GHC.Word (Word8)
import qualified HA.EQTracker.Process as EQT
import           HA.EventQueue.Producer
import           HA.Multimap
import           HA.NodeUp (nodeUp')
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import qualified HA.RecoveryCoordinator.Castor.Node.Actions as Node
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.RC.Actions.Core
import           HA.RecoveryCoordinator.RC.Events.Cluster
import           HA.RecoveryCoordinator.Service.Events
import           HA.Replicator
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources as R (Node(..))
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.SafeCopy (base, deriveSafeCopy)
import qualified HA.Services.DecisionLog as DL
import           HA.Services.Mero (putM0d)
import qualified HA.Services.Mero.Mock as Mock
import           HA.Services.SSPL
import           HA.Services.SSPL.LL.Resources
import           HA.Services.SSPL.Rabbit
import           Helper.InitialData
import           Mero.ConfC (ServiceType(CST_HA))
import           Network.CEP
import           Network.Transport
import           RemoteTables (remoteTable)
import           Test.Tasty.HUnit (Assertion)
import           TestRunner

-- | Set of configuration options used for environment setup and test
-- execution. This is provided to the test runner.
data TestOptions = TestOptions
  { _to_initial_data :: !CI.InitialData
  -- ^ Initial data to use for cluster setup and test environment.
  , _to_run_decision_log :: !Bool
  -- ^ Should we run decision-log service?
  , _to_run_sspl :: !Bool
  -- ^ Should we run SSPL service?
  , _to_cluster_setup :: !ClusterSetup
  -- ^ State of the environment to set up before the tast is ran.
  , _to_remote_table :: !RemoteTable
  -- ^ Remote table used during the test. 'remoteTable' by default.
  -- It's recommended that you modify this field with your module's
  -- @__remoteTableDecl@ instead of replacing it all together.
  , _to_scheduler_runs :: !Int
  -- ^ How many times to repeat the test if scheduler is used.
  , _to_ts_nodes :: !Word8
  -- ^ How many nodes should be TS, except the RC node.
  , _to_modify_halon_vars :: HalonVars -> HalonVars
  -- ^ How to modify 'HalonVars' before the test is ran. Note that if
  -- the test is not using this function, it should ask for
  -- 'HalonVars' from the RG instead of using 'defaultHalonVars' to
  -- preserve any changes test runner has made.
  }

data RmqSetup = RmqSetup
  { -- | RMQ proxy 'ProcessId'.
    _rmq_pid :: !ProcessId
    -- | Publish the given message to the proxy exchange that will
    -- then forward to the sensor exchange.
  , _rmq_publishSensorMsg :: ByteString -> Process ()
  }

-- | Set of values from the environment setup that can be used
-- throughout test execution. This is provided to the test itself.
data TestSetup = TestSetup
  { _ts_rc :: !ProcessId
  -- ^ RC 'ProcessId'
  , _ts_eq :: !ProcessId
  -- ^ EQ 'ProcessId'
  , _ts_mm :: !StoreChan
  -- ^ MM 'ProcessId'
  , _ts_rmq :: ~RmqSetup
  -- ^ RMQ setup information. Lazy as might not be set-up.
  , _ts_nodes :: ![LocalNode]
  -- ^ Group of nodes involved in the test
  , _ts_ts_nodes :: ![LocalNode]
  -- ^ '_ts_nodes' that are tracking stations, excluding RC node.
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


-- | Ask RC to put mock version of @halon:m0d@ service in RG.
-- Optionally set the cluster disposition to online.
data MockM0 = MockM0 !ProcessId !Bool
  deriving (Show, Eq, Generic, Typeable)
instance Binary MockM0

-- | Reply to 'MockM0'
data MockM0Reply = MockM0RequestOK !NodeId
                 | MockM0RequestFailed !String
  deriving (Generic, Typeable)
instance Binary MockM0Reply


-- | Ask RC to start a mock version of @halon:m0d@ service.
data PopulateMock = PopulateMock !ProcessId !NodeId
                  -- ^ PopulateMock @halon:m0d-worker-pid@ @target-node@
  deriving (Show, Eq, Ord, Generic, Typeable)

-- | Reply to 'MockM0'
data PopulateMockReply = MockRunning !NodeId
                       | MockPopulateFailure !NodeId !String
  deriving (Show, Eq, Ord, Generic, Typeable)
instance Binary PopulateMockReply

-- | Used to fire internal test rules. Many tests define a single rule
-- that they want to fire and reply from: this provides a common type
-- for that.
newtype RuleHook = RuleHook ProcessId
  deriving (Generic, Typeable, Binary)

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

    let ourProc l = return $! case getField $ rget fldProc l of
          Nothing -> error "testRules.ourProc: no HA process in local state"
          Just p -> (p, \s -> s == M0.PSOnline)
        cmdAck m _ l = return $ case (m, getField $ rget fldMockAck l) of
          (u :: Mock.MockCmdAck, Just u') | u == u' -> Just ()
          _ -> Nothing

        route (PopulateMock m0dPid nid) = do
          rg <- getGraph
          let procs = Node.getProcesses (R.Node nid) rg
              pmap = map (\p -> (p, G.connectedTo p M0.IsParentOf rg)) procs
              ha = [ p | (p, svcs) <- pmap
                       , any (\s -> M0.s_type s == CST_HA) svcs ]
          case ha of
            [ha_p] -> do
              mack <- liftProcess $ Mock.sendMockCmd (Mock.SetProcessMap pmap) m0dPid
              modify Local $ rlens fldProc . rfield .~ Just ha_p
              modify Local $ rlens fldMockAck . rfield .~ Just mack
              return $ Right ( MockPopulateFailure nid $ "default: " ++ show nid
                             , [process_map_set, timeout 10 mock_timed_out] )
            _ -> do
              return $ Right ( MockPopulateFailure nid $ "didn't find unique HA: " ++ show ha
                             , [finish] )

    setPhaseIf process_map_set cmdAck $ \() -> do
      PopulateMock m0dPid _ <- getRequest
      mack <- liftProcess $ Mock.sendMockCmd Mock.MockInitialiseFinished m0dPid
      modify Local $ rlens fldMockAck . rfield .~ Just mack
      switch [mock_initialise_done, timeout 10 mock_timed_out]

    setPhaseIf mock_initialise_done cmdAck $ \() -> do
      switch [mock_up, timeout 20 mock_timed_out]

    setPhaseNotified mock_up ourProc $ \_ -> do
      PopulateMock _ nid <-  getRequest
      modify Local $ rlens fldRep . rfield .~ Just (MockRunning nid)
      continue finish

    directly mock_timed_out $ do
      PopulateMock _ nid <- getRequest
      modify Local $ rlens fldRep . rfield .~ Just
        (MockPopulateFailure nid $ "Timed out waiting for mock on " ++ show nid)
      continue finish

    return route
    where
      fldReq = Proxy :: Proxy '("request", Maybe PopulateMock)
      fldRep = Proxy :: Proxy '("reply", Maybe PopulateMockReply)
      fldProc = Proxy :: Proxy '("process", Maybe M0.Process)
      fldMockAck = Proxy :: Proxy '("mock-ack", Maybe Mock.MockCmdAck)
      args = fldProc    =: Nothing
         <+> fldMockAck =: Nothing
         <+> fldReq     =: Nothing
         <+> fldRep     =: Nothing


-- | Start satellite nodes. This is intended to be ran from tracking
-- station node.
startSatellites :: [NodeId] -- ^ EQ nodes
                -> [(LocalNode, T.Text)] -- ^ @(node, hostname)@ pairs
                -> Process ()
startSatellites _ [] = sayTest "startSatellites called without any nodes."
startSatellites eqs ns = withSubscription eqs (Proxy :: Proxy NewNodeConnected) $ do
  liftIO . for_ ns $ \(n, h) -> forkProcess n $ do
    -- TS nodes already have EQT registered but SATs-only don't:
    -- start EQT on SAT-only nodes if necessary
    whereis EQT.name >>= \case
      Nothing -> void $ EQT.startEQTracker []
      Just{} -> return ()
    sayTest $ "Sending nodeUp for: " ++ show (h, localNodeId n)
    nodeUp' h eqs

  let loop [] = return ()
      loop waits = receiveWait
        [ matchIf (\(pubValue -> NewNodeConnected n _) -> n `elem` waits)
                  (\(pubValue -> NewNodeConnected n _) -> loop $ filter (/= n) waits) ]
      nodes = map (\(ln, _) -> R.Node $! localNodeId ln) ns
  sayTest $ "Waiting for following satellites: " ++ show nodes
  loop nodes
  sayTest "startSatellites finished."

-- | Create some default 'TestOptions' for a test.
mkDefaultTestOptions :: IO TestOptions
mkDefaultTestOptions = do
  idata <- defaultInitialData
  return $ TestOptions
    { _to_initial_data = idata
    , _to_run_decision_log = True
    , _to_run_sspl = True
    , _to_cluster_setup = NoSetup
    , _to_remote_table = TestRunner.__remoteTableDecl remoteTable
    , _to_scheduler_runs = 20
    , _to_ts_nodes = 0
    , _to_modify_halon_vars = id
    }

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
     -- ^ Test options
     -> (TestSetup -> Process ())
     -- ^ Test itself
     -> Assertion
run' transport pg extraRules to test = do
  let idata = _to_initial_data to
      numNodes = length (CI.id_m0_servers idata)
      rt = _to_remote_table to
      runs = _to_scheduler_runs to

  runTest (numNodes + 1) runs 15000000 transport rt $ \lnodes -> do
    -- Wipe the halon:m0d state from any previous test runs.
    liftIO Mock.clearMockState
    sayTest $ "Starting setup for a " ++ show numNodes ++ " node test."
    let lnWithHosts = zip lnodes $ map CI.m0h_fqdn (CI.id_m0_servers idata)
        nids = map localNodeId lnodes
        ts_nodes = take (fromIntegral $ _to_ts_nodes to) lnodes

    withTrackingStations pg (testRules:extraRules) ts_nodes $ \ta -> do
      let rcNodeId = processNodeId $ ta_rc ta
      link (ta_rc ta)
      self <- getSelfPid

      -- Start satellites before initial data is loaded as otherwise
      -- RC rules will try to start processes on node automatically.
      -- We want a potential clean bootstrap.
      startSatellites [rcNodeId] lnWithHosts

      when (_to_run_decision_log to) $ do
        _ <- serviceStartOnNodes [rcNodeId] DL.decisionLog (DL.processOutput self) nids
        sayTest "Started decision log services."

      withSubscription [rcNodeId] (Proxy :: Proxy HalonVarsUpdated) $ do
        let hvars = _to_modify_halon_vars to $
              defaultHalonVars { _hv_mero_workers_allowed = False }
        promulgateEQ_ [rcNodeId] $ SetHalonVars hvars
        HalonVarsUpdated{} <- expectPublished
        return ()

      withSubscription [rcNodeId] (Proxy :: Proxy InitialDataLoaded) $ do
        promulgateEQ_ [rcNodeId] idata
        expectPublished >>= \case
          InitialDataLoaded -> return ()
          InitialDataLoadFailed e -> fail e

      when (_to_run_sspl to) $ do
        _ <- serviceStartOnNodes [rcNodeId] sspl ssplConf nids
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
                            promulgateEQ_ [rcNodeId] $ PopulateMock m0dPid nid
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

      -- Before we do much of anything, set a mock halon:m0d in the RG
      -- so that nothing tries to run the real deal.
      let mockMsg = MockM0 self (_to_cluster_setup to == HalonM0DOnly)
      usend (ta_rc ta) mockMsg
      receiveWait [ matchIf (\m -> m == mockMsg) (\_ -> return ()) ]
      sayTest "halon:m0d mock implanted in RG."

      case _to_cluster_setup to of
        Bootstrapped -> do
          withSubscription [rcNodeId] (Proxy :: Proxy ClusterStartResult) $ do
            promulgateEQ_ [rcNodeId] ClusterStartRequest
            startM0Ds
            expectPublished >>= \case
              ClusterStartOk -> sayTest "Cluster bootstrap finished."
              e -> fail $ "Cluster fail to bootstrap with: " ++ show e
        HalonM0DOnly -> do
          rg' <- G.getGraph (ta_mm ta)
          for_ (mapMaybe (\n -> M0.nodeToM0Node (R.Node n) rg') nids) $ \m0n -> do
            promulgateEQ_ [rcNodeId] $! StartHalonM0dRequest m0n
            sayTest $ "Sent StartHalonM0dRequest for " ++ show m0n
          startM0Ds
        NoSetup -> sayTest "No setup requested."

      rmq <- case _to_run_sspl to of
        True -> do
          rmq <- spawnMockRabbitMQ self
          sayTest "Started mock RabbitMQ service."
          return rmq
        False -> do
          sayTest "No RabbitMQ proxy as no SSPL requested."
          return $ error "RabbitMQ service not initialised"

      sayTest "Starting test..."
      test $ TestSetup
        { _ts_eq = ta_eq ta
        , _ts_mm = ta_mm ta
        , _ts_rc = ta_rc ta
        , _ts_rmq = rmq
        , _ts_nodes = lnodes
        , _ts_ts_nodes = ts_nodes }
      sayTest "Test finished! Cleaning..."

      when (_to_run_sspl to) $ do
        for_ nids $ \nid -> do
          serviceStopOnNode [rcNodeId] sspl nid >>= \case
            ServiceStopRequestOk -> return ()
            r -> fail $ "SSPL failed to stop with: " ++ show r
          return ()
        unlink (_rmq_pid rmq)
        kill (_rmq_pid rmq) "end of game"
      sayTest "All done!"
  where
    -- exchanges
    iemX     = "test-x-sspl-in"
    cmdX     = "test-x-sspl-in"
    cmdRespX = "test-x-sspl-out"
    sensorX  = "test-x-sspl-out"
    proxyX   = "test-x-proxy"

    -- routing keys
    iemK     = "test-k-iem"
    cmdK     = "test-k-cmd"
    cmdRespK = "test-k-cmd-resp"
    sensorK  = "test-k-sensor"
    proxyK   = "test-k-proxy"

    -- queues
    iemQ     = "test-q-iem"
    cmdQ     = "test-q-cmd"
    cmdRespQ = "test-q-cmd-resp"
    sensorQ  = "test-q-sensor"
    proxyQ   = "test-q-proxy"

    mkBindConf exchange routingKey queue =
      BindConf (Configured exchange) (Configured routingKey) (Configured queue)

    rabbitConnectionConf = ConnectionConf
      (Configured "localhost") (Configured "/") ("guest") ("guest")

    ssplConf = SSPLConf
      rabbitConnectionConf
      (SensorConf $ mkBindConf sensorX sensorK sensorQ)
      (ActuatorConf (mkBindConf iemX iemK iemQ)
                    (mkBindConf cmdX cmdK cmdQ)
                    (mkBindConf cmdRespX cmdRespK cmdRespQ)
                    (Configured 1000000))

    spawnMockRabbitMQ :: ProcessId -> Process RmqSetup
    spawnMockRabbitMQ self = do
      pid <- spawnLocal $ do
        link self
        rabbitMQProxy rabbitConnectionConf
      sayTest "Clearing RMQ queues."
      purgeRmqQueues pid [sensorQ, iemQ, cmdQ, cmdRespQ, proxyQ]

      -- Bind the send queues we'll need whether halon:sspl did it
      -- first or not.
      usend pid $ MQBind sensorX sensorQ sensorK
      usend pid $ MQBind cmdRespX cmdRespQ cmdRespK

      -- We want to be able to send messages to halon:sspl but also to
      -- be able to see the things we send. As RMQ uses round-robin to
      -- dispatch messages from queues to its consumers, we can't
      -- subscribe to the same queue as halon:sspl. Deal with this by
      -- creating an intermediate queue used by the proxy and inspect
      -- that then forward the message to halon:sspl exchange/queue.
      usend pid $ MQBind proxyX proxyQ proxyK
      usend pid $ MQForward proxyQ sensorX sensorQ sensorK self

      -- We want to know what messages halon:sspl sends. This is
      -- straight forward as the proxy pretends to be SSPL simply by
      -- consuming what halon:sspl sends. This will make the proxy
      -- send us MQMessage with the content.
      usend pid $ MQBind iemX iemQ iemK
      usend pid $ MQBind cmdX cmdQ cmdK
      usend pid $ MQSubscribe iemQ self

      -- Real SSPL returns messages in full on the command ack queue
      -- when it has processed them. Tell proxy to just forward
      -- messages from the command queue to command ack queue. This
      -- also subscribes us to 'commandQueue' which is desired.
      usend pid $ MQForward cmdQ cmdRespX cmdRespQ cmdRespK self

      sayTest "RMQ queues purged."
      link pid
      return $! RmqSetup
        { _rmq_pid = pid
        , _rmq_publishSensorMsg = usend pid . MQPublish proxyX proxyK
        }

deriveSafeCopy 0 'base ''PopulateMock
