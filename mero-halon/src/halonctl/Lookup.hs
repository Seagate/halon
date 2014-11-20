-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Lookup (conjureRemoteNodeId) where

import Control.Distributed.Process

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
#endif

conjureRemoteNodeId :: String -> NodeId
conjureRemoteNodeId addr =
#ifdef USE_RPC
  -- TODO
  error "undefined RPCMethod"
#else
    NodeId $ TCP.encodeEndPointAddress host port 0
  where
    sa = TCP.decodeSocketAddress addr
    host = TCP.socketAddressHostName sa
    port = TCP.socketAddressServiceName sa
#endif
