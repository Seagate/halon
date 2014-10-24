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
    , nodeAgentLabel
    ) where

#ifdef USE_RPC
import qualified HA.Network.IdentifyRPC as Identify
import HA.Network.Transport (readTransportGlobalIVar)
import qualified Network.Transport.RPC as RPC
import Data.Word (Word32)
#else
import qualified HA.Network.IdentifyTCP as Identify
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
#endif
import Control.Distributed.Process
import Control.Monad (join)

#ifdef USE_RPC
nodeAgentMagic :: Word32
nodeAgentMagic = 5
#endif

#ifdef USE_RPC
advertiseNodeAgent :: ProcessId -> Process (Maybe Identify.IdentifyId)
advertiseNodeAgent pid = do
    -- TODO: error handling
    transport <- readTransportGlobalIVar
    liftIO $ Identify.putAvailable transport nodeAgentMagic (processNodeId pid)
#else
advertiseNodeAgent :: TCP.PortNumber -> ProcessId -> Process (Maybe Identify.IdentifyId)
advertiseNodeAgent port pid =
    liftIO (Identify.putAvailable (fromIntegral $ port) (processNodeId pid))
#endif

#ifdef USE_RPC
lookupNodeAgent :: RPC.RPCAddress -> Process (Maybe ProcessId)
lookupNodeAgent addr = do
    transport <- readTransportGlobalIVar
    mnid <- liftIO $ Identify.getAvailable transport addr nodeAgentMagic
    maybe (return Nothing) getNodeAgent mnid
#else
lookupNodeAgent :: TCP.SockAddr -> Process (Maybe ProcessId)
lookupNodeAgent addr = do
    host <- liftIO $ TCP.inet_ntoa (TCP.socketAddressHost addr)
    let port = fromIntegral $ TCP.socketAddressPort addr
    mnid <- liftIO $ Identify.getAvailable host port
    maybe (return Nothing) getNodeAgent mnid
#endif

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
