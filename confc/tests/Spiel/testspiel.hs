--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This program does a basic test of the Spiel command interface.

import Mero (withM0)
import Mero.Concurrent
import Mero.ConfC
import Mero.Spiel

import Network.RPC.RPCLite

import Control.Monad (join)

import System.Environment ( getArgs )

withEndpoint :: RPCAddress -> (ServerEndpoint -> IO a) -> IO a
withEndpoint addr f = do
    ep <- listen addr listenCallbacks
    f ep
  where
    listenCallbacks = ListenCallbacks
      { receive_callback = \it _ ->  putStr "Received: "
                                      >> unsafeGetFragments it
                                      >>= print
                                      >> return True
      }

testMain :: String -> String -> String -> IO ()
testMain localAddress confdAddress rmAddress =
  withEndpoint (rpcAddress localAddress) $ \ep -> do
    rpcMach <- getRPCMachine_se ep
    withConf rpcMach (rpcAddress confdAddress) $ \rootNode -> do
      profiles <- (children rootNode :: IO [Profile])
      print profiles
      fs <- join <$> mapM (children :: Profile -> IO [Filesystem]) profiles
      nodes <- join <$> mapM (children :: Filesystem -> IO [Node]) fs
      processes <- join <$> mapM (children :: Node -> IO [Process]) nodes
      withSpiel rpcMach [confdAddress] rmAddress $ \spiel -> do
        print processes
        services <- join <$> mapM (children :: Process -> IO [Service]) processes
        print services
        setCmdProfile spiel Nothing
        runningServices <- join <$> mapM (processListServices spiel) processes
        print runningServices

main :: IO ()
main = withM0 $ do
  initRPC
  m0t <- forkM0OS $ do
    getArgs >>= \[ l , c, r ] -> testMain l c r
  joinM0OS m0t
  finalizeRPC
