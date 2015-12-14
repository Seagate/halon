{-# LANGUAGE ScopedTypeVariables #-}
--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This program does a basic test of the Spiel command interface.
module Test.CopyConf (name, test) where

import Mero (withM0)
import Mero.Concurrent
import Mero.ConfC
import Mero.Spiel

import Network.RPC.RPCLite

import Control.Monad
import System.IO

import Helper

testMain :: String -> String -> IO ()
testMain localAddress confdAddress =
  withEndpoint (rpcAddress localAddress) $ \ep -> do
    rpcMach <- getRPCMachine_se ep
    withConf rpcMach (rpcAddress confdAddress) $ \rootNode ->
      withHASession ep (rpcAddress confdAddress) $
        withSpiel rpcMach $ \spiel ->
          withTransaction spiel $ \transaction -> do
            profiles <- children rootNode :: IO [Profile]
            forM_ profiles $ \p ->
              spliceTree transaction (rt_fid rootNode) p


name :: String
name = "copy-confd-configuration-as-is"

test :: IO ()
test = withM0 $ do
  initRPC
  m0t <- forkM0OS $ join $ testMain <$> getHalonEndpoint 
                                    <*> getConfdEndpoint
  joinM0OS m0t
  hPutStrLn stderr "About to finalize RPC"
  finalizeRPC
