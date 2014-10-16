-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import HA.NodeAgent (NodeAgentConf(..), nodeAgent, serviceProcess)
import HA.Network.Address
import HA.Network.RemoteTables (haRemoteTable)
import HA.NodeAgent.Lookup (advertiseNodeAgent)
import HA.Process
import HA.Service (sDict)
import Mero.RemoteTables (meroRemoteTable)

import Control.Distributed.Process
import Control.Distributed.Process.Closure (staticDecode)
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode)
import Control.Distributed.Static (closureApply)

import Control.Applicative ((<$>))
import Data.Binary (encode)
import Data.Defaultable
import System.Environment
import System.IO ( hFlush, stdout )

buildType :: String
#ifdef USE_RPC
buildType = "RPC"
#else
buildType = "TCP"
#endif

printHeader :: IO ()
printHeader = do
  putStrLn $ "This is halon-node-agent/" ++ buildType
  hFlush stdout

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

naConf :: NodeAgentConf
naConf = NodeAgentConf {
    softTimeout = Default 500000
  , timeout = Default 1000000
}

main :: IO Int
main = do
  config <- parseArgs <$> getArgs
  network <- startNetwork (localEndpoint config)
  lnid <- newLocalNode (getNetworkTransport network) myRemoteTable
  tryRunProcess lnid $
     do liftIO $ printHeader
        nid <- getSelfNode
        napid <- spawn nid $ (serviceProcess nodeAgent)
                  `closureApply` closure (staticDecode sDict) (encode naConf)
        _ <- advertiseNodeAgent network (localLookup config) napid
        receiveWait [] -- wait indefinitely
  return 0
