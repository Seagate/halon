--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This program does a basic test of the Spiel command interface.
module Test.Management (test,name) where

import Mero (withM0)
import Mero.Concurrent
import Mero.ConfC
import Mero.Spiel

import Network.RPC.RPCLite

import Control.Monad (join)

import System.IO
import Data.Foldable (forM_)

import Helper

testMain :: String -> String -> IO ()
testMain localAddress confdAddress = do
  withEndpoint (rpcAddress localAddress) $ \ep -> do
    hPutStrLn stderr "with-endpoint"
    rpcMach <- getRPCMachine_se ep
    hPutStrLn stderr "with-conf"
    withConf rpcMach (rpcAddress confdAddress) $ \rootNode -> do
      withHASession ep (rpcAddress confdAddress) $ do
        profiles <- (children rootNode :: IO [Profile])
        printErr $ map cp_fid profiles
        withSpiel rpcMach $ \spiel -> do
         forM_ profiles $ \p -> do
           printErr p
           fs <- (children :: Profile -> IO [Filesystem]) p
           nodes <- join <$> mapM (children :: Filesystem -> IO [Node]) fs
           processes <- join <$> mapM (children :: Node -> IO [Process]) nodes
           printErr processes
           services <- join <$> mapM (children :: Process -> IO [Service]) processes
           printErr services
           setCmdProfile spiel (Just (show $ cp_fid p))
           withRConf spiel $ do
             runningServices <- join <$> mapM (processListServices spiel) processes
             printErr runningServices

name :: String
name = "management-commands"

test :: IO ()
test = withM0 $ do
    initRPC
    hPutStrLn stderr "start test"
    m0t <- forkM0OS $ join $ testMain <$> getHalonEndpoint 
                                      <*> getConfdEndpoint
    joinM0OS m0t
    hPutStrLn stderr "about to finalize"
    finalizeRPC
