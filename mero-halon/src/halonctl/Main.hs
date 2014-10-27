-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import HA.Network.RemoteTables (haRemoteTable)
import HA.NodeAgent
  ( NodeAgentConf(..) )
import HA.Process
import HA.RecoveryCoordinator.Mero.Startup

import Handler.Bootstrap.NodeAgent (startNA)

import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
#endif

import Control.Applicative ((<$>))
import Control.Distributed.Process.Closure ( mkClosure, functionTDict )
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode)
import Data.Defaultable

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
    do liftIO $ printHeader
       self <- getSelfNode
       startNA self naConf
       liftIO $ putStrLn $ "Starting Recovery Supervisors."
       result <- call $(functionTDict 'ignition) self $
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
            mapM_ print $ [ tracker | (Nothing, tracker) <- zip mpids trackers ]
          Nothing -> return ()
  return 0
