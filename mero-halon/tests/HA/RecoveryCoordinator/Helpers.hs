{-# LANGUAGE CPP #-}
-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Collection of helper functions used by the HA.RecoveryCoordinator
-- family of tests.
module HA.RecoveryCoordinator.Helpers where

import           Control.Distributed.Process
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.Multimap
#ifdef USE_MOCK_REPLICATOR
import           HA.Replicator.Mock ( MC_RG )
#else
import           HA.Replicator.Log ( MC_RG )
#endif
import           HA.RecoveryCoordinator.Mero
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Service
  ( Configuration
  , Service(..)
  , ServiceName(..)
  , ServiceProcess(..)
  , ServiceStart(..)
  , ServiceStarted(..)
  , ServiceStartRequest(..)
  , decodeP
  , encodeP
  , runningService
  )
import           HA.Services.Monitor
import           Network.CEP (Published(..))
import           Network.Transport (Transport(..))
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
serviceStarted :: ServiceName -> Process ProcessId
serviceStarted svname = do
    mp@(Published (HAEvent _ msg _) _)          <- expect
    ServiceStarted _ svc _ (ServiceProcess pid) <- decodeP msg
    if serviceName svc == svname
        then return pid
        else do
          self <- getSelfPid
          usend self mp
          serviceStarted svname

-- | Start the given 'Service' on the current node.
serviceStart :: Configuration a => Service a -> a -> Process ()
serviceStart svc conf = do
    nid <- getSelfNode
    let node = Node nid
    _   <- promulgateEQ [nid] $ encodeP $ ServiceStartRequest Start node svc conf []
    return ()

-- | Get the regular monitor pid of the current node.
getNodeMonitor :: StoreChan -> Process ProcessId
getNodeMonitor mm = do
    nid <- getSelfNode
    rg  <- G.getGraph mm
    let n = Node nid
    case runningService n regularMonitor rg of
      Just (ServiceProcess pid) -> return pid
      _  -> do
        _ <- receiveTimeout 100 []
        getNodeMonitor mm

-- | Gets the pid of the given service on the given node. It blocks
-- until the service actually starts.
getServiceProcessPid :: Configuration a
                     => StoreChan
                     -> Node
                     -> Service a
                     -> Process ProcessId
getServiceProcessPid mm n sc = do
    rg <- G.getGraph mm
    case runningService n sc rg of
      Just (ServiceProcess pid) -> return pid
      _ -> do
        _ <- receiveTimeout 500000 []
        getServiceProcessPid mm n sc

-- | Tests that the given service is still alive. Tries 3 times and
-- then gives up.
serviceProcessStillAlive :: Configuration a
                         => StoreChan
                         -> Node
                         -> Service a
                         -> Process Bool
serviceProcessStillAlive mm n sc = loop (1 :: Int)
  where
    loop i | i > 3     = return True
           | otherwise = do
                 rg <- G.getGraph mm
                 case runningService n sc rg of
                   Just _ -> do
                     _ <- receiveTimeout 250000 []
                     loop (i + 1)
                   _ -> return False

-- | Start the RC without any extra rules. For custom rules, see
-- 'runRCEx'.
runRC :: (ProcessId, IgnitionArguments) -- ^ (EQ, ignition arguments)
      -> MC_RG TestReplicatedState
      -> Process ((StoreChan, ProcessId)) -- ^ MM, RC
runRC (eq, args) rGroup = runRCEx (eq, args) emptyRules rGroup