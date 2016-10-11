-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import Lookup
import Version.Read

import HA.Network.RemoteTables (haRemoteTable)

import Handler.Bootstrap
import Handler.Cluster
import Handler.Service
import Handler.Status
import Handler.Debug

import Mero.RemoteTables (meroRemoteTable)

import Network.Transport (closeTransport)
#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
#else
import Network.Transport.TCP as TCP
#endif

import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , closeLocalNode
  , runProcess
  )
import Control.Monad.Catch
import Data.Traversable
import Data.Maybe (fromMaybe)

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

main :: IO ()
main = getOptions >>= maybe version run

version :: IO ()
version = do
  printHeader
  versionString >>= putStrLn

run :: Options -> IO ()
run (Options { .. }) =
#ifdef USE_RPC
  bracket (RPC.createTransport "s1" (RPC.rpcAddress $ optOurAddress)
                                    RPC.defaultRPCParameters
          ) closeTransport $ \rpcTransport -> do
  writeTransportGlobalIVar rpcTransport
  let transport = RPC.networkTransport rpcTransport
#else
  let (hostname, _:port) = break (== ':') optOurAddress in
  bracket (either (error . show) id <$>
               TCP.createTransport hostname port
               defaultTCPParameters { tcpUserTimeout = Just 2000
                                    , tcpNoDelay = True
                                    , transportConnectTimeout = Just 2000000
                                    }
          ) closeTransport $ \transport ->
#endif
  bracket (newLocalNode transport myRemoteTable) closeLocalNode $ \lnid -> do
  let rnids = fmap conjureRemoteNodeId optTheirAddress
  runProcess lnid $ do
    replies <- forM rnids $ \nid -> do
      (_, mref) <- spawnMonitor nid (returnCP sdictUnit ())
      let mkErrorMsg msg = "Error connecting to " ++ show nid ++ ": " ++ msg
      fromMaybe [mkErrorMsg "connect timeout"] <$> receiveTimeout 5000000
        [ matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
                  (\(ProcessMonitorNotification _ _ dr) -> do
                      return $ case dr of
                        DiedException e -> [mkErrorMsg $ "got exception (" ++ e ++ ")."]
                        DiedDisconnect -> [mkErrorMsg  "node disconnected."]
                        DiedNodeDown -> [mkErrorMsg "node is down."]
                        _ -> []
                  )
        ]

    if null $ concat replies
      then case optCommand of
          Bootstrap bs -> bootstrap rnids bs
          Service bs   -> service rnids bs
          Cluster bs   -> cluster rnids bs
          Status  bs   -> status rnids bs
          Debug bs     -> debug rnids bs
      else do
        say "Failed to connect to controlled nodes: "
        liftIO $ mapM_ putStrLn $ concat replies
        _ <- receiveTimeout 1000000 [] -- XXX: give a time to output logs
        return ()
  return ()
