-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Flags
import HA.NodeAgent.Lookup (lookupNodeAgent)
import System.Environment
import Control.Applicative ((<$>))
import Control.Distributed.Process.Closure ( mkClosure, functionTDict )
import Control.Distributed.Process
import HA.Network.Address
import Control.Distributed.Process.Platform.Test (tryRunProcess)
import Control.Distributed.Process.Node (newLocalNode)
import HA.RecoveryCoordinator.Mero.Startup
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)
import Control.Distributed.Process.Node (initRemoteTable)

buildType :: String
#ifdef USE_RPC
buildType = "RPC"
#else
buildType = "TCP"
#endif

printHeader :: IO ()
printHeader =
  putStrLn $ "This is ha-station/" ++ buildType

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO Int
main = do
  config <- parseArgs <$> getArgs
  network <- startNetwork (localEndpoint config)
  lnid <- newLocalNode (getNetworkTransport network) myRemoteTable
  tryRunProcess lnid $
    do liftIO $ printHeader
       mpid <- lookupNodeAgent network (localLookup config)
       case mpid of
          Nothing -> error "No node agent found at specified address"
          Just pid -> do
            liftIO $ putStrLn $ "Starting Recovery Coordinator on " ++ show pid
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
