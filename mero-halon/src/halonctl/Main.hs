-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import Lookup

import HA.Network.RemoteTables (haRemoteTable)

import Handler.Bootstrap
import Handler.Cluster
import Handler.Service
import Handler.Status

import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
#else
import Network.Transport.TCP as TCP
#endif

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )
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
main = getOptions >>= run

run :: Options -> IO ()
run (Options { .. }) = do
#ifdef USE_RPC
  rpcTransport <- RPC.createTransport "s1"
                                      (RPC.rpcAddress $ optOurAddress)
                                      RPC.defaultRPCParameters
  writeTransportGlobalIVar rpcTransport
  let transport = RPC.networkTransport rpcTransport
#else
  let (hostname, _:port) = break (== ':') optOurAddress
  transport <- either (error . show) id <$>
               TCP.createTransport hostname port
               defaultTCPParameters { tcpUserTimeout = Just 2000
                                    , tcpNoDelay = True
                                    , transportConnectTimeout = Just 2000000
                                    }
#endif
  lnid <- newLocalNode transport myRemoteTable
  let rnids = fmap conjureRemoteNodeId optTheirAddress
  runProcess lnid $ do
    liftIO $ printHeader
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
      else do
        say "Failed to connect to controlled nodes: "
        liftIO $ mapM_ putStrLn $ concat replies
        _ <- receiveTimeout 1000000 [] -- XXX: give a time to output logs
        return ()
  return ()
