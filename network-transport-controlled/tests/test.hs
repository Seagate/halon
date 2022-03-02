-- |
-- Module: Main
-- Copyright: (C) 2015 Seagate Technology LLC and/or its Affiliates. 
--
module Main
  ( main
  ) where

import Network.Transport.InMemory
import qualified Network.Transport.Controlled as Controlled

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Concurrent
import Control.Monad

main :: IO ()
main = testSimple >> testAnotherProcess

-- | Test that 'ProcessMonitorNotification' will be receive when we
-- monitor process on remote node and connection between nodes is
-- broken, while we are communicating with that process.
testSimple :: IO ()
testSimple = do
  (controlled, node1, node2) <- setup

  pid <- forkProcess node1 $ do
    p <- expect
    send p ()
    receiveWait []

  runProcess node2 $ do
    _ <- monitor pid
    p <- getSelfPid
    n <- getSelfNode
    send pid p
    expect :: Process ()
    liftIO $ Controlled.silenceBetween controlled (nodeAddress n) (nodeAddress $ processNodeId pid)
    spawnLocal $ forever $ receiveTimeout 1000 [] >> send pid ()
    ProcessMonitorNotification _ _ _ <- expect
    liftIO $ putStrLn "ok"
    return ()

-- | Test that is we receive process monitor notification when
-- connection was teared down but we do not communicate with process
-- beign monitored.
testAnotherProcess :: IO ()
testAnotherProcess = do
  (controlled, node1, node2) <- setup

  pid <- forkProcess node1 $ do
    p <- expect
    send p ()
    receiveWait []
  pid2 <- forkProcess node1 $ receiveWait []

  runProcess node2 $ do
    _ <- monitor pid2
    self <- getSelfPid
    p <- getSelfPid
    n <- getSelfNode
    send pid p
    expect :: Process ()
    liftIO $ Controlled.silenceBetween controlled (nodeAddress n) (nodeAddress $ processNodeId pid)
    send pid ()
    ProcessMonitorNotification _ _ _ <- expect
    liftIO $ putStrLn "ok"
    return ()

setup :: IO (Controlled.Controlled, LocalNode, LocalNode)
setup = do
  (transport,internals) <- createTransportExposeInternals
  let closeConnection here there =
        breakConnection internals here there "user error"
  (transport',controlled) <- Controlled.createTransport transport closeConnection
  node1 <- newLocalNode transport' initRemoteTable
  node2 <- newLocalNode transport' initRemoteTable
  return (controlled, node1, node2)
