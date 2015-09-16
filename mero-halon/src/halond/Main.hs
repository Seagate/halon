-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import Prelude hiding ((<$>))
import Flags
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
#else
import Network.Transport.TCP as TCP
#endif
import HA.RecoveryCoordinator.Definitions
import HA.Startup (startupHalonNode)

import Control.Applicative ((<$>))
import Control.Distributed.Commands.Process (sendSelfNode)
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Closure ( mkStaticClosure )
import Control.Distributed.Process.Node
import Control.Distributed.Static ( closureCompose )

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

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO ()
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
    let (hostname, _:port) = break (== ':') $ localEndpoint config
    transport <- either (error . show) id <$>
                 TCP.createTransport hostname port TCP.defaultTCPParameters
                   { tcpUserTimeout = Just 2000
                   , tcpNoDelay = True
                   , transportConnectTimeout = Just 2000000
                   }
#endif
    lnid <- newLocalNode transport myRemoteTable
    printHeader (localEndpoint config)
    runProcess lnid sendSelfNode
    startupHalonNode lnid (Just $ localEndpoint config) rcClosure
  where
    rcClosure = $(mkStaticClosure 'recoveryCoordinator) `closureCompose`
                  $(mkStaticClosure 'ignitionArguments)
