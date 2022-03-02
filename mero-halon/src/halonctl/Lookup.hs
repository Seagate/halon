-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

module Lookup
  ( conjureRemoteNodeId
  , findEQFromNodes
  ) where

import           Control.Distributed.Process
import qualified Network.Transport.TCP.Internal as TCP
import qualified HA.EQTracker                   as EQT

conjureRemoteNodeId :: String -> NodeId
conjureRemoteNodeId addr =
    NodeId $ TCP.encodeEndPointAddress host port 0
  where
    (host, _:port) = break (== ':') addr

-- | Look up the location of the EQ by querying the EQTracker(s) on the
--   provided node(s)
findEQFromNodes :: Int -- ^ Timeout in microseconds
                -> [NodeId]
                -> Process [NodeId]
findEQFromNodes t n = go t n [] where
  go 0 [] nids = go 0 (reverse nids) []
  go _ [] _ = return []
  go timeout (x:xs) done = do
    EQT.lookupReplicas x
    rl <- expectTimeout timeout
    case rl of
      Just (EQT.ReplicaReply (EQT.ReplicaLocation _ rest@(_:_))) -> return rest
      _ -> go timeout xs (x : done)
