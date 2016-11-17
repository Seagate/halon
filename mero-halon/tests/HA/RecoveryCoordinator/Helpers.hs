{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Collection of helper functions used by the HA.RecoveryCoordinator
-- family of tests.
module HA.RecoveryCoordinator.Helpers where

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.Service
import           HA.RecoveryCoordinator.Events.Service
import           HA.Resources
import           HA.Encode
import           Network.CEP (Published(..))
import           Network.Transport (Transport(..))
import           Data.Typeable
import           Prelude hiding ((<$>), (<*>))
import           RemoteTables ( remoteTable )
import           TestRunner

-- | Run the test with some common test parameters
runDefaultTest :: Transport -> Process () -> IO ()
runDefaultTest transport act =   runTest 1 20 15000000 transport testRemoteTable $ \_ -> act

testRemoteTable :: RemoteTable
testRemoteTable = TestRunner.__remoteTableDecl $
                  remoteTable

-- | Awaits a message about the start of the given service. Waits
-- until the right message is received.
serviceStarted :: Typeable a => Service a -> Process ProcessId
serviceStarted srv = do
  (Published (HAEvent _ (ServiceStarted _ msg pid)) _) <- expect
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
