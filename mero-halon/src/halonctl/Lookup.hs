-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.

module Lookup
  ( conjureRemoteNodeId
  , findEQFromNodes
  ) where

import qualified HA.EQTracker as EQT
import           Network.Transport.TCP (encodeEndPointAddress)
import           Control.Distributed.Process
  ( NodeId(..)
  , Process
  , expectTimeout
  )

conjureRemoteNodeId :: String -> NodeId
conjureRemoteNodeId addr =
    let (host, _:port) = break (== ':') addr
    in NodeId (encodeEndPointAddress host port 0)

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
