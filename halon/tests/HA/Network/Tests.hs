{-# LANGUAGE CPP #-}

module HA.Network.Tests ( tests ) where

import Test.Framework

import HA.Network.Address ( Network, Address, getNetworkTransport )
#ifdef USE_RPC
import qualified HA.Network.IdentifyRPC as Identify
#else
import HA.Network.Address ( parseAddress, hostOfAddress )
import qualified HA.Network.IdentifyTCP as Identify
#endif
import RemoteTables ( remoteTable )

import Control.Concurrent.MVar
import Control.Distributed.Process hiding (bracket)
import Control.Exception (bracket)


tests :: Address -> Network -> IO [TestTree]
tests addr network = do
    let transport = getNetworkTransport network
    return
        [ testSuccess "network-nodeagent-advertize-lookup" $ do
#ifdef USE_RPC
              let laddr = addr
#else
              let Just laddr = parseAddress $ hostOfAddress addr ++ ":8087"
#endif
              bracket
                  newEmptyMVar
                  (\miid -> do
                       iid <- takeMVar miid
                       putStrLn "Closing putAvailable ..."
                       Identify.closeAvailable iid)
                  (\miid -> tryWithTimeout transport remoteTable defaultTimeout $ do
                       done <- liftIO $ newEmptyMVar
                       let mockNA = liftIO $ takeMVar done
                       napid <- spawnLocal mockNA
                       register nodeAgentLabel napid
                       Just iid <- advertiseNodeAgent network laddr napid
                       liftIO $ putMVar miid iid
                       Just _ <- lookupNodeAgent network laddr
                       liftIO $ putMVar done ()) ]
