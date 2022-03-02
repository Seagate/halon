{-# LANGUAGE CPP             #-}
{-# LANGUAGE RecursiveDo     #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiWayIf      #-}
{-# LANGUAGE ViewPatterns    #-}
-- |
-- Module    : Main
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
--                 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Main entry point to halon.
module Main (main) where

import Control.Distributed.Commands.Process (sendSelfNode)
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Closure ( mkStaticClosure )
import Control.Distributed.Process.Node
import Flags
import HA.Network.RemoteTables (haRemoteTable)
import HA.RecoveryCoordinator.Definitions
import HA.Startup (startupHalonNode)
import Mero.RemoteTables (meroRemoteTable)
import Network.Transport.TCP as TCP
import System.Directory ( getCurrentDirectory )
import System.Environment
import System.IO
import Version.Read

printHeader :: String -> IO ()
printHeader listen = do
    cwd <- getCurrentDirectory
    putStrLn $ "This is halond/TCP listening on " ++ listen
    putStrLn $ "Working directory: " ++ show cwd
    versionString >>= putStrLn
    hFlush stdout

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO ()
main = do
  -- Default buffering mode may result in gibberish in systemd logs.
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  config <- parseArgs <$> getArgs
  case mode config of
    Version -> versionString >>= putStrLn
    Help -> putStrLn helpString
    Run -> do
        -- TODO: Implement a mechanism to propagate env vars in distributed tests.
        -- Perhaps an env var like
        -- DC_PROPAGATE_ENV="HALON_TRACING DISTRIBUTED_PROCESS_TRACE_FILE"
        -- which enumerates the environment variables that must be propagated when
        -- spawning remote processes.
        whenTestIsDistributed $
          setEnvIfUnset "HALON_TRACING"
           "consensus-paxos replicated-log EQ EQ.producer MM RS RG call startup"
        let (hostname, _:port) = break (== ':') $ localEndpoint config
        transport <- either (error . show) id <$>
                     TCP.createTransport (defaultTCPAddr hostname port) TCP.defaultTCPParameters
                       { tcpUserTimeout = Just 2000
                       , tcpNoDelay = True
                       , transportConnectTimeout = Just 2000000
                       }
        lnid <- newLocalNode transport myRemoteTable
        printHeader (localEndpoint config)
        runProcess lnid sendSelfNode
        runProcess lnid $ startupHalonNode rcClosure >> receiveWait []
  where
    rcClosure = $(mkStaticClosure 'recoveryCoordinator)

    whenTestIsDistributed action = do
      lookupEnv "DC_CALLER_PID" >>= maybe (return ()) (const action)

    setEnvIfUnset v x = lookupEnv v >>= maybe (setEnv v x) (const $ return ())
