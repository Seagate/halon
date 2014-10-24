-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import HA.Network.RemoteTables (haRemoteTable)
import HA.NodeAgent.Lookup (lookupNodeAgent)
import HA.Process
import HA.RecoveryCoordinator.Mero.Startup
import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
#endif

import Control.Distributed.Process.Node (initRemoteTable)

import Control.Applicative ((<$>))
import Control.Distributed.Process.Closure ( mkClosure, functionTDict )
import Control.Distributed.Process
import Control.Distributed.Process.Node (newLocalNode)
import System.Environment

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

main :: IO Int
main = do
  config <- parseArgs <$> getArgs
#ifdef USE_RPC
  transport <- RPC.createTransport "s1" (localEndpoint config) RPC.defaultRPCParameters
  writeNetworkGlobalIVar transport
#else
  let TCP.SockAddrInet port hostaddr = TCP.decodeSocketAddress $ localEndpoint config
  hostname <- TCP.inet_ntoa hostaddr
  transport <- either (error . show) id <$>
               TCP.createTransport hostname (show port) TCP.defaultTCPParameters
#endif
  lnid <- newLocalNode transport myRemoteTable
  tryRunProcess lnid $
    do liftIO $ printHeader
#ifdef USE_RPC
       mpid <- lookupNodeAgent $ RPC.rpcAddress $ localLookup config
#else
       mpid <- lookupNodeAgent $ TCP.decodeSocketAddress $ localLookup config
#endif
       case mpid of
          Nothing -> error $ "No node agent found at " ++ localLookup config
          Just pid -> do
            liftIO $ putStrLn $ "Starting Recovery Supervisors from " ++ show pid
            result <- call $(functionTDict 'ignition) (processNodeId pid) $
                       $(mkClosure 'ignition) (update config)
            case result of
              Just (added, trackers, mpids, members, newNodes) -> liftIO $ do
                if added then do
                  putStrLn "The following nodes joined successfully:"
                  mapM_ print newNodes
                 else
                  putStrLn "No new node could join the group."
                putStrLn ""
                putStrLn "The following nodes were already in the group:"
                mapM_ print members
                putStrLn ""
                putStrLn "The following nodes could not be contacted:"
                mapM_ putStrLn $ [ tracker | (Nothing, tracker) <- zip mpids trackers ]
              Nothing -> return ()
  return 0
