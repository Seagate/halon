-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import HA.Network.RemoteTables (haRemoteTable)
import HA.Process

import Handler.Bootstrap

import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
#endif

import Control.Applicative ((<$>))
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode)

buildType :: String
#ifdef USE_RPC
buildType = "RPC"
#else
buildType = "TCP"
#endif

printHeader :: IO ()
printHeader =
  putStrLn $ "This is halonctl/" ++ buildType

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

conjureRemoteNodeId :: String -> NodeId
conjureRemoteNodeId addr =
#ifdef USE_RPC
  -- TODO
  undefinedRPCMethod
#else
    NodeId $ TCP.encodeEndPointAddress host port 0
  where
    sa = TCP.decodeSocketAddress addr
    host = TCP.socketAddressHostName sa
    port = TCP.socketAddressServiceName sa
#endif

main :: IO ()
main = getOptions >>= run

run :: Options -> IO ()
run (Options { .. }) = do
#ifdef USE_RPC
  transport <- RPC.createTransport "s1" optOurAddress RPC.defaultRPCParameters
  writeNetworkGlobalIVar transport
#else
  let sa = TCP.decodeSocketAddress optOurAddress
      hostname = TCP.socketAddressHostName sa
      port = TCP.socketAddressServiceName sa
  transport <- either (error . show) id <$>
               TCP.createTransport hostname port TCP.defaultTCPParameters
#endif
  lnid <- newLocalNode transport myRemoteTable
  let rnids = fmap conjureRemoteNodeId optTheirAddress
  tryRunProcess lnid $ do
    liftIO $ printHeader
    case optCommand of
      Bootstrap bs -> bootstrap rnids bs
  return ()
