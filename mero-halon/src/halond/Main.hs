-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import HA.NodeAgent (NodeAgentConf(..), nodeAgent, serviceProcess)
import HA.Network.RemoteTables (haRemoteTable)
import HA.Process
import HA.Service (sDict)
import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
#endif

import Control.Distributed.Process
import Control.Distributed.Process.Closure (staticDecode)
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode)
import Control.Distributed.Static (closureApply)

import Control.Applicative ((<$>))
import Data.Binary (encode)
import Data.Defaultable
import System.Environment
import System.IO ( hFlush, stdout )

printHeader :: String -> IO ()
printHeader listen = do
    putStrLn $ "This is halond/" ++ buildType ++ " listening on " ++ listen
    hFlush stdout
  where
#ifdef USE_RPC
    buildType = "RPC"
#else
    buildType = "TCP"
#endif

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

naConf :: NodeAgentConf
naConf = NodeAgentConf
  { softTimeout = Default 500000
  , timeout = Default 1000000
  }

main :: IO Int
main = do
  config <- parseArgs <$> getArgs
#ifdef USE_RPC
  transport <- RPC.createTransport "s1" (localEndpoint config) RPC.defaultRPCParameters
  writeNetworkGlobalIVar transport
#else
  let sa = TCP.decodeSocketAddress $ localEndpoint config
      hostname = TCP.socketAddressHostName sa
      port = TCP.socketAddressServiceName sa
  transport <- either (error . show) id <$>
               TCP.createTransport hostname port TCP.defaultTCPParameters
#endif
  lnid <- newLocalNode transport myRemoteTable
  tryRunProcess lnid $
     do liftIO $ printHeader (localEndpoint config)
        nid <- getSelfNode
        _ <- spawn nid $ (serviceProcess nodeAgent)
                  `closureApply` closure (staticDecode sDict) (encode naConf)
        receiveWait [] -- wait indefinitely
  return 0
