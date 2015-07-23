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
#endif

conjureRemoteNodeId :: String -> NodeId
conjureRemoteNodeId addr =
#ifdef USE_RPC
    NodeId $ RPC.encodeEndPointAddress (RPC.rpcAddress addr)
                                       (RPC.EndPointKey 10)
#else
    NodeId $ TCP.encodeEndPointAddress host port 0
  where
    (host, _:port) = break (== ':') addr
#endif
