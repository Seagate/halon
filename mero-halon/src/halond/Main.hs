-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Main (main) where

import Prelude hiding ((<$>))
import Flags
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
#endif

import Control.Applicative ((<$>))
import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , localNodeId
  , runProcess
  )

import qualified Data.Binary

#ifdef USE_MERO
import Mero
import Mero.M0Worker
#endif
import System.Environment
import System.IO ( hFlush, stdout , hSetBuffering, BufferMode(..))

printHeader :: String -> IO ()
printHeader listen = do
    hSetBuffering stdout LineBuffering
    putStrLn $ "This is halond/" ++ buildType ++ " listening on " ++ listen
    hFlush stdout
  where
#ifdef USE_RPC
    buildType = "RPC"
#else
    buildType = "TCP"
#endif

-- | Prints the given 'NodeId' in the standard output.
printNodeId :: NodeId -> IO ()
printNodeId n = do print $ Data.Binary.encode n
                   -- XXX: an extra line of outputs seems to be needed when
                   -- programs are run through ssh so the output is actually
                   -- received.
                   putStrLn ""
                   hFlush stdout

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO Int
#ifdef USE_MERO
main = withM0 $ do
  startGlobalWorker
#else
main = do
#endif
  config <- parseArgs <$> getArgs
#ifdef USE_RPC
  rpcTransport <- RPC.createTransport "s1"
                                      (RPC.rpcAddress $ localEndpoint config)
                                      RPC.defaultRPCParameters
  writeTransportGlobalIVar rpcTransport
  let transport = RPC.networkTransport rpcTransport
#else
  let sa = TCP.decodeSocketAddress $ localEndpoint config
      hostname = TCP.socketAddressHostName sa
      port = TCP.socketAddressServiceName sa
  transport <- either (error . show) id <$>
               TCP.createTransport hostname port TCP.defaultTCPParameters
#endif
  lnid <- newLocalNode transport myRemoteTable
  -- Print the node id for the testing framework.
  printNodeId .localNodeId $ lnid
  printHeader (localEndpoint config)
  runProcess lnid $ receiveWait []
  return 0
