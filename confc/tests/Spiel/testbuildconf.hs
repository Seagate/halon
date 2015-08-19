{-# LANGUAGE ScopedTypeVariables #-}
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

import Control.Exception (bracket)
import Control.Monad (forM_)

import System.Environment ( getArgs )

withEndpoint :: RPCAddress -> (ServerEndpoint -> IO a) -> IO a
withEndpoint addr = bracket
    (listen addr listenCallbacks)
    stopListening
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
      withSpiel rpcMach [confdAddress] rmAddress $ \spiel -> do
        withTransaction spiel $ \transaction -> do
          profiles <- children rootNode :: IO [Profile]
          forM_ profiles $ \p -> do
            spliceTree transaction (rt_fid rootNode) p

main :: IO ()
main = withM0 $ do
  initRPC
  m0t <- forkM0OS $ do
    getArgs >>= \[ l , c, r ] -> testMain l c r
  joinM0OS m0t
  putStrLn "About to finalize RPC"
  finalizeRPC
