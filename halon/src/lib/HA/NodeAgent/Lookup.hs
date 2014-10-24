-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- The purpose of the node agent is to provide the Recovery Coordinator (or its
-- proxy) the ability to access services running on worker nodes. Commands to
-- the node agent are delivered as Cloud Haskell messages. Services are named
-- Haskell processes running on the host machine. This process must respond to
-- the following synchronous (i.e. having an implicit response) messages.

{-# LANGUAGE CPP #-}

module HA.NodeAgent.Lookup
    ( lookupNodeAgent
    , advertiseNodeAgent
    , getNodeAgent
    , nodeAgentLabel ) where

import Control.Distributed.Process
import Control.Monad (join)
#ifdef USE_RPC
import qualified HA.Network.IdentifyRPC as Identify
#else
import qualified HA.Network.IdentifyTCP as Identify
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
#endif
import HA.Network.Address
#ifdef USE_RPC
import Data.Word (Word32)
#endif

#ifdef USE_RPC
nodeAgentMagic :: Word32
nodeAgentMagic = 5
#endif

advertiseNodeAgent :: Network -> Address -> ProcessId -> Process (Maybe Identify.IdentifyId)
advertiseNodeAgent network addr pid =
-- TODO: error handling
#ifdef USE_RPC
  let (Network rpctrans) = network
   in addr `seq` liftIO $ Identify.putAvailable rpctrans nodeAgentMagic (processNodeId pid)
#else
  -- need to reference network to avoid spurious "defined but not used" warning
  network `seq`
    liftIO (Identify.putAvailable (fromIntegral $ TCP.socketAddressPort addr) (processNodeId pid))
#endif

lookupNodeAgent :: Network -> Address -> Process (Maybe ProcessId)
#ifdef USE_RPC
lookupNodeAgent network addr =
#else
lookupNodeAgent _ addr =
#endif
  do
#ifdef USE_RPC
     mnid <- liftIO $ Identify.getAvailable (getNetworkTransport network) addr nodeAgentMagic
#else
     host <- liftIO $ TCP.inet_ntoa (TCP.socketAddressHost addr)
     let port = fromIntegral $ TCP.socketAddressPort addr
     mnid <- liftIO $ Identify.getAvailable host port
#endif
     maybe (return Nothing) getNodeAgent mnid

nodeAgentLabel :: String
nodeAgentLabel = "HA.NodeAgent"

-- | Given a CH NID, identify the PID of the
-- node agent running in that node. If the node
-- cannot be contacted or there is no node agent,
-- returns Nothing
getNodeAgent :: NodeId -> Process (Maybe ProcessId)
getNodeAgent nid = do
    whereisRemoteAsync nid label
    fmap join $ receiveTimeout thetime
                 [ matchIf (\(WhereIsReply label' _) -> label == label')
                           (\(WhereIsReply _ mPid) -> return mPid)
                 ]
  where
    label = nodeAgentLabel
    thetime = 5000000
