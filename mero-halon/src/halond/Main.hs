-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import Flags
import Version

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

import Control.Distributed.Commands.Process (sendSelfNode)
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Closure ( mkStaticClosure )
import Control.Distributed.Process.Node

#ifdef USE_MERO
import Mero
import Mero.Environment
#endif
import System.Directory (getCurrentDirectory)
import System.Environment
import System.IO ( hFlush, stdout , hSetBuffering, BufferMode(..))

printHeader :: String -> IO ()
printHeader listen = do
    cwd <- getCurrentDirectory
    hSetBuffering stdout LineBuffering
    putStrLn $ "This is halond/" ++ buildType ++ " listening on " ++ listen
    putStrLn $ "Working directory: " ++ show cwd
    versionString >>= putStrLn
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
main = do
  config <- parseArgs <$> getArgs
  case mode config of
    Version -> versionString >>= putStrLn
    Help -> putStrLn helpString
    Run -> do
#ifdef USE_MERO
      withM0Deferred initializeFOPs deinitializeFOPs $ mdo
#endif
        -- TODO: Implement a mechanism to propagate env vars in distributed tests.
        -- Perhaps an env var like
        -- DC_PROPAGATE_ENV="HALON_TRACING DISTRIBUTED_PROCESS_TRACE_FILE"
        -- which enumerates the environment variables that must be propagated when
        -- spawning remote processes.
        whenTestIsDistributed $
          setEnvIfUnset "HALON_TRACING"
           "consensus-paxos replicated-log EQ EQ.producer MM RS RG call startup"
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
        runProcess lnid $ startupHalonNode rcClosure >> receiveWait []
  where
    rcClosure = $(mkStaticClosure 'recoveryCoordinator)

    whenTestIsDistributed action = do
      lookupEnv "DC_CALLER_PID" >>= maybe (return ()) (const action)

    setEnvIfUnset v x = lookupEnv v >>= maybe (setEnv v x) (const $ return ())
