-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Lookup
  ( conjureRemoteNodeId
  , findEQFromNodes
  ) where

import qualified HA.EQTracker          as EQT

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

-- | Look up the location of the EQ by querying the EQTracker(s) on the
--   provided node(s)
findEQFromNodes :: Int -- ^ Timeout in microseconds
                -> [NodeId]
                -> Process [NodeId]
findEQFromNodes t n = go t n [] where
  go 0 [] nids = go 0 (reverse nids) []
  go _ [] _ = error "Failed to query EQ location from any node."
  go timeout (x:xs) done = do
    EQT.lookupReplicas x
    rl <- expectTimeout timeout
    case rl of
      Just (EQT.ReplicaReply (EQT.ReplicaLocation _ rest@(_:_))) -> return rest
      _ -> go timeout xs (x : done)
