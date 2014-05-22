-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import HA.NodeAgent (nodeAgent, serviceProcess)
import HA.Process
import Control.Distributed.Process
import Control.Distributed.Process.Node (newLocalNode)
import System.Environment
import Control.Applicative ((<$>))
import HA.Network.Address
import HA.NodeAgent.Lookup (advertiseNodeAgent)
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)
import Control.Distributed.Process.Node	(initRemoteTable)

import System.IO ( hFlush, stdout )


buildType :: String
#ifdef USE_RPC
buildType = "RPC"
#else
buildType = "TCP"
#endif

printHeader :: IO ()
printHeader = do
  putStrLn $ "This is ha-node-agent/" ++ buildType
  hFlush stdout

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO Int
main = do
  config <- parseArgs <$> getArgs
  network <- startNetwork (localEndpoint config)
  lnid <- newLocalNode (getNetworkTransport network) myRemoteTable
  tryRunProcess lnid $
     do liftIO $ printHeader
        nid <- getSelfNode
        napid <- spawn nid (serviceProcess nodeAgent)
        _ <- advertiseNodeAgent network (localLookup config) napid
        receiveWait [] -- wait indefinitely
  return 0
