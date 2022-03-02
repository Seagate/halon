{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MonoLocalBinds      #-}

-- |
-- Module    : HA.RecoveryCoordinator.Helpers
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Collection of helper functions used by the HA.RecoveryCoordinator
-- family of tests.
--
-- TODO: Fold into other helpers and only have one module.

module HA.RecoveryCoordinator.Helpers where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad (void)
import Data.Foldable (for_)
import Data.Function (fix)
import Data.Text (Text)
import Data.Typeable
import HA.Encode
import HA.EventQueue.Producer (promulgateEQ)
import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Job.Actions (startJob)
import HA.RecoveryCoordinator.Job.Events (JobFinished(..))
import HA.RecoveryCoordinator.RC.Subscription
import HA.RecoveryCoordinator.Service.Events
import HA.Resources
import HA.Service
import HA.Services.SSPL.Rabbit
import Network.CEP (Published(..))
import Network.Transport (Transport(..))
import RemoteTables (remoteTable)
import Test.Framework (TestTree, withTmpDirectory)
import Test.Tasty.HUnit (testCase)
import TestRunner

-- | Run the test with some common test parameters
runDefaultTest :: Transport -> Process () -> IO ()
runDefaultTest transport act = runTest 1 20 15000000 transport testRemoteTable $ \_ -> act

-- | Tag a test with @[require-mero]@ and run it inside a temporary
-- directory.
testMero :: String -> IO () -> TestTree
testMero n = testCase ("[require-mero] " ++ n) . withTmpDirectory

testRemoteTable :: RemoteTable
testRemoteTable = TestRunner.__remoteTableDecl remoteTable

-- | Awaits a message about the start of the given service. Waits
-- until the right message is received.
--
-- Note that it will discard any 'ServiceStarted' messages that are
-- also in the inbox before the message we're after even if their
-- underlying service is not the correct one.
serviceStarted :: Typeable a => Service a -> Process ProcessId
serviceStarted srv = do
  ServiceStarted _ msg pid <- eventPayload . pubValue <$> expect
  ServiceInfo srvi _ <- decodeP msg
  if maybe False (srv==) (cast srvi)
  then return pid
  else serviceStarted srv

-- | Start the given 'Service' on the current node.
serviceStart :: Configuration a => Service a -> a -> Process ()
serviceStart svc conf = do
  nid <- getSelfNode
  let node = Node nid
  _   <- promulgateEQ [nid] $ encodeP $ ServiceStartRequest Start node svc conf []
  return ()

-- | Start the given 'Service' on given nodes. Blocks until every
-- service has started.
--
-- Caveat from 'serviceStarted' applies. Returns 'ProcessId' of the
-- started service for each of the nodes.
serviceStartOnNodes :: Configuration a
                    => [NodeId]
                    -- ^ Location of EQ nodes for subscription purposes.
                    -> Service a
                    -- ^ Service to start
                    -> a
                    -- ^ Service 'Configuration'
                    -> [NodeId]
                    -- ^ Nodes to start the service on.
                    -> Process [(NodeId, ProcessId)]
serviceStartOnNodes eqs svc conf nids = withSubscription eqs startedEvent $ do
  for_ nids $ \nid -> do
    void . promulgateEQ eqs . encodeP $ ServiceStartRequest Start (Node nid) svc conf []

  let loop [] results = return results
      loop waits results = do
        ServiceStarted (Node nid) msg pid <- eventPayload . pubValue <$> expect
        case nid `elem` waits of
          True -> do
            ServiceInfo svci _ <- decodeP msg
            case maybe False (svc ==) (cast svci) of
              True -> do
                loop (filter (/= nid) waits) ((nid, pid) : results)
              False -> loop waits results
          False -> loop waits results
  loop nids []
  where
    startedEvent = Proxy :: Proxy (HAEvent ServiceStarted)

serviceStopOnNode :: Configuration a
                  => [NodeId]
                  -- ^ Location of EQ nodes for subscription purposes.
                  -> Service a
                  -- ^ Service to stop
                  -> NodeId
                  -- ^ Node to stop the service on.
                  -> Process ServiceStopRequestResult
serviceStopOnNode eqs svc nid = withSubscription eqs svcStopFinished $ do
  l <- startJob . encodeP $ ServiceStopRequest (Node nid) svc
  JobFinished _ v <- expectPublishedIf (\(JobFinished lis _) -> l `elem` lis)
  return v
  where
    svcStopFinished :: Proxy (JobFinished ServiceStopRequestResult)
    svcStopFinished = Proxy

-- | Subscribe then unsubscribe for the duration of the given action.
withSubscription :: Serializable a
                 => [NodeId] -- ^ EQ nodes
                 -> Proxy a -- ^ Event to subscribe to for duration of the action
                 -> Process b -- ^ The action
                 -> Process b
withSubscription eqs p act = do
  subscribeOnTo eqs p
  r <- act
  unsubscribeOnFrom eqs p
  return r

-- | 'expect' a 'Published' message that satisfies the predicate. It
-- is up to the caller to have previously subscribed to the message.
--
-- Discards any messages in the inbox that don't satisfy the predicate.
expectPublishedIf :: forall a. Serializable a => (a -> Bool) -> Process a
expectPublishedIf p = do
  let t = show $ typeRep (Proxy :: Proxy a)
  fix $ \loop -> do
    sayTest $ "Expecting " ++ t ++ " to be published."
    r <- receiveWait [ match $ \(Published m _) -> return m ]
    sayTest $ "Received a published " ++ t
    if p r
    then return r
    else do
      sayTest $ "Predicate on published " ++ t ++ " failed, retrying."
      loop

-- | 'expect' a 'Published' message. It is up to the caller to have
-- previously subscribed to the message.
expectPublished :: forall a. Serializable a => Process a
expectPublished = expectPublishedIf $ \(_ :: a) -> True

-- | Gets the pid of the given service on the given node. It blocks
-- until the service actually starts.
getServiceProcessPid :: Configuration a
                     => Node
                     -> Service a
                     -> Process ProcessId
getServiceProcessPid (Node nid) sc = do
  whereisRemoteAsync nid (serviceLabel sc)
  WhereIsReply _ (Just pid) <- expect
  return pid

emptyMailbox :: Serializable t => Proxy t -> Process ()
emptyMailbox t@(Proxy :: Proxy t) = expectTimeout 0 >>= \case
  Nothing -> return ()
  Just (_ :: t) -> emptyMailbox t

-- | Prepend 'say' with @test =>@ for easy log search.
sayTest :: String -> Process ()
sayTest m = say $ "test => " ++ m

-- | Purge any messages from the given rabbitmq queues. Useful to
-- clear queues between tests. If you want to empty the queue from old
-- messages, you probably want to call this before 'MQSubscribe' which
-- will put the messages from the queue on a channel.
purgeRmqQueues :: ProcessId -- ^ RMQ 'ProcessId'
               -> [Text]  -- ^ Queues to purge
               -> Process ()
purgeRmqQueues rmq qs = do
  self <- getSelfPid
  for_ qs $ \q -> do
    let msg = MQPurge q self
    usend rmq msg
    _ <- receiveTimeout (5 * 1000000)
      [ matchIf (\m -> m == msg) (\_ -> return ()) ]
    return ()
