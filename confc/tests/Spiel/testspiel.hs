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
import Control.Exception (bracket)

import System.Environment ( getArgs )
import Data.Foldable (forM_)

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
testMain localAddress confdAddress rmAddress = do
  putStrLn "1"
  withEndpoint (rpcAddress localAddress) $ \ep -> do
    rpcMach <- getRPCMachine_se ep
    putStrLn "with-conf"
    withConf rpcMach (rpcAddress confdAddress) $ \rootNode -> do
      profiles <- (children rootNode :: IO [Profile])
      print $ map cp_fid profiles
      withSpiel rpcMach [confdAddress] rmAddress $ \spiel -> do
        forM_ profiles $ \p -> do
          setCmdProfile spiel (Just (show $ cp_fid p))
          print p
          fs <- (children :: Profile -> IO [Filesystem]) p
          nodes <- join <$> mapM (children :: Filesystem -> IO [Node]) fs
          processes <- join <$> mapM (children :: Node -> IO [Process]) nodes
          print processes
          services <- join <$> mapM (children :: Process -> IO [Service]) processes
          print services
          runningServices <- join <$> mapM (processListServices spiel) processes
          print runningServices

main :: IO ()
main = do
  withM0 $ do
    initRPC
    putStrLn "start test"
    m0t <- forkM0OS $ do
      getArgs >>= \[ l , c, r ] -> testMain l c r
    joinM0OS m0t
    putStrLn "about to finalize"
    finalizeRPC
