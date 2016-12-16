-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of helpers for distributed tests.

module HA.Test.Distributed.Helpers where

import Control.Distributed.Process
import Data.Proxy
import HA.RecoveryCoordinator.RC.Events.Cluster
import HA.RecoveryCoordinator.RC
import HA.Resources
import Network.CEP hiding (timeout)

-- | Requests 'ProcessId' of the RC. Uses the EQ running on the
-- given 'NodeId'. Subscribes to events that may be interesting to
-- distributed tests.
waitForRCAndSubscribe :: [NodeId] -- ^ EQ nodes
                      -> Process ()
waitForRCAndSubscribe nids = do
  subscribeOnTo nids (Proxy :: Proxy NewNodeConnected)

-- | Wait until 'NewNodeConnected' for given 'NodeId' is published by the RC.
waitForNewNode :: NodeId -> Int -> Process (Maybe NodeId)
waitForNewNode nid t = receiveTimeout t
  [ matchIf (\(Published (NewNodeConnected (Node nid')) _) -> nid == nid')
            (const $ return nid)
  ]

dummyStartedLine :: String
dummyStartedLine = "[Service:dummy] starting at "

dummyAlreadyLine :: String
dummyAlreadyLine = "[Service:dummy] already running"

pingStartedLine :: String
pingStartedLine = "[Service:ping] starting at "
