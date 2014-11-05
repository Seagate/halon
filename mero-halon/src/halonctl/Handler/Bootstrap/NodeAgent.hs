-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- NodeAgent service proxy module. This serves to run the NodeAgent, which is
-- necesary at the moment for certain parts of the system.

module Handler.Bootstrap.NodeAgent
  ( NodeAgentConf
  , start
  )
where

import Control.Distributed.Process
  ( Process
  , NodeId
  , closure
  , say
  , spawn
  )
import Control.Distributed.Process.Closure (staticDecode)
import Control.Distributed.Static (closureApply)

import Data.Binary (encode)

import HA.NodeAgent (NodeAgentConf(..), nodeAgent, serviceProcess)
import HA.Service (sDict)

self :: String
self = "HA.NodeAgent"

start :: NodeId -> NodeAgentConf -> Process ()
start nid naConf = do
    say $ "This is " ++ self
    _ <- spawn nid $ (serviceProcess nodeAgent)
      `closureApply` closure (staticDecode sDict) (encode naConf)
    return ()
