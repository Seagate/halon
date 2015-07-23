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
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
#endif
import HA.Process (tryRunProcess)
import HA.RecoveryCoordinator.Definitions
import HA.Startup (autoboot)

import Control.Applicative ((<$>))
import Control.Distributed.Commands.Process (sendSelfNode)
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Closure ( mkStaticClosure )
import Control.Distributed.Process.Node
import Control.Distributed.Static ( closureCompose )
import Control.Exception (SomeException, catch)

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
    let (hostname, _:port) = break (== ':') $ localEndpoint config
    transport <- either (error . show) id <$>
                 TCP.createTransport hostname port TCP.defaultTCPParameters
#endif
    lnid <- newLocalNode transport myRemoteTable
    printHeader (localEndpoint config)
    -- Attempt to autoboot the TS
    catch (tryRunProcess lnid $ autoboot rcClosure)
          (\(e :: SomeException) -> putStrLn $ "Cannot autoboot: " ++ show e)
    runProcess lnid $ do
      -- Send the node id to the test driver if any.
      sendSelfNode
      receiveWait []
    return 0
  where
    rcClosure = $(mkStaticClosure 'recoveryCoordinator) `closureCompose`
                  $(mkStaticClosure 'ignitionArguments)
