{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module    : HA.RecoveryCoordinator.Helpers
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of helper functions used by the HA.RecoveryCoordinator
-- family of tests.
--
-- TODO: Fold into other helpers and only have one module (or 2, for mero).
module HA.RecoveryCoordinator.Helpers where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Typeable
import HA.Encode
import HA.EventQueue.Producer (promulgateEQ)
import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Service.Events
import HA.Resources
import HA.Service
import HA.Services.SSPL.Rabbit
import Network.CEP (Published(..))
import Network.Transport (Transport(..))
import RemoteTables ( remoteTable )
import TestRunner

-- | Run the test with some common test parameters
runDefaultTest :: Transport -> Process () -> IO ()
runDefaultTest transport act = runTest 1 20 15000000 transport testRemoteTable $ \_ -> act

testRemoteTable :: RemoteTable
testRemoteTable = TestRunner.__remoteTableDecl $
                  remoteTable

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

-- | 'expect' a 'Published' message. It is up to the caller to have
-- previously subscribed to the message.
expectPublished :: Serializable a => Proxy a -> Process a
expectPublished p = do
  say $ "Expecting " ++ show (typeRep p) ++ " to be published."
  Published r _ <- expect
  say $ "Received a published " ++ show (typeRep p)
  return r

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
    let msg = MQPurge (encodeUtf8 q) self
    usend rmq msg
    Just{} <- receiveTimeout (5 * 1000000)
      [ matchIf (\m -> m == msg) (\_ -> return ()) ]
    return ()
