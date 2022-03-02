--
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Tests the distributed process interface for distributed tests.
--
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

import Control.Distributed.Commands.IPTables
import Control.Distributed.Commands.Process
  ( withHostNames
  , copyFiles
  , systemThere
  , redirectLogs
  , expectLog
  , sendSelfNode
  , __remoteTable
  , mkTraceEnv
  , TraceEnv(..)
  )
import Control.Distributed.Commands.Providers

import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )
import Control.Exception (AssertionFailed(AssertionFailed))
import Control.Exception.Lifted (throwIO)
import Control.Monad
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.Environment
import System.Exit
import System.FilePath ((</>), takeFileName)


remotableDecl [[d|
  relayMsgs :: Process ()
  relayMsgs = forever $ do
    (sender, nid, label, m) <- expect
    say $ show sender
    nsendRemote nid label (sender :: ProcessId, m :: String)
 |]]


main :: IO ()
main = do
    TraceEnv spawnNode' gatherTraces <- mkTraceEnv

    localHost <- getHostAddress
    nt <- either throwIO return =<< createTransport localHost "4000" defaultTCPParameters
    let remoteTable = __remoteTableDecl $ __remoteTable initRemoteTable
    n0 <- newLocalNode nt remoteTable

    args <- getArgs
    exePath <- getExecutablePath
    let pingServerLabel = "ping-server"
    case args of
      ["--ping-server"] -> do
        runProcess n0 $ do
          getSelfPid >>= register pingServerLabel
          sendSelfNode
          forever $ do
            (pid, m) <- expect
            say $ show pid
            usend pid (m :: String)
        exitSuccess
      _ -> return ()

    cp <- getProvider

    runProcess n0 $ withHostNames cp 2 $ \ms@[m0, m1] -> do

      -- test copying a folder
      say "Testing copying files ..."
      copyFiles m0 [m1] [ ("/var/tmp", "test-halon-cp-folder") ]
      copyFiles "localhost" [m0, m1] [(exePath, ".")]

      say "Testing running a remote command ..."
      systemThere ms ("echo can run a remote command")

      systemThere ms ("true")

      er <- try $ systemThere ms ("false")
      case er of
        Right _ -> liftIO $ throwIO (AssertionFailed "systemThere of 'false' returned a successful exit")
        Left (_ :: IOError) -> return ()

      -- test spawning a node
      say "Testing spawning nodes ..."

      nid0 <- spawnNode' "m0" m0 $
                "DC_HOST_IP=" ++ m0 ++
                  " ." </> takeFileName exePath ++ " --ping-server"
      getSelfPid >>= redirectLogs nid0
      nid1 <- spawnNode' "m1" m1 $
                "DC_HOST_IP=" ++ m1 ++
                  " ." </> takeFileName exePath ++ " --ping-server"
      getSelfPid >>= redirectLogs nid1

      say "Testing log redirection ..."
      self <- getSelfPid
      nsendRemote nid0 pingServerLabel (self, "0")

      expectLog [nid0] (== show self)
      "0" <- expect

      say "Testing link cuts ..."
      relayer <- spawn nid1 $(mkStaticClosure 'relayMsgs)

      -- test relaying and establish a tcp connection between m0 and m1 for the
      -- next test
      usend relayer (self, nid0, pingServerLabel, "1")
      "1" <- expect
      expectLog [nid1] (== show self)

      -- cut the link in one direction and test that messages still relay
      liftIO $ cutLinksAsUser "root" [m0] [m1]
      usend relayer (self, nid0, pingServerLabel, "2")
      "2" <- expect
      expectLog [nid1] (== show self)

      -- now cut the link in the other direction and test that messages don't
      -- relay
      liftIO $ cutLinksAsUser "root" [m1] [m0]
      usend relayer (self, nid0, pingServerLabel, "3")
      Nothing <- receiveTimeout 1000000 [ matchIf (== "3") return ]
      expectLog [nid1] (== show self)

      say "Testing reenabling links ..."
      -- now restore the link and check that it works
      liftIO $ reenableLinksAsUser "root" [m1] [m0]
      liftIO $ reenableLinksAsUser "root" [m0] [m1]
      usend relayer (self, nid0, pingServerLabel, "4")
      _ <- receiveWait [ matchIf (== "4") return ]
      expectLog [nid1] (== show self)

      say "Testing isolation ..."
      liftIO $ isolateHostsAsUser "root" [m0] ms
      usend relayer (self, nid0, pingServerLabel, "5")
      Nothing <- receiveTimeout 1000000 [ matchIf (== "5") return ]
      expectLog [nid1] (== show self)

      say "Testing rejoining ..."
      liftIO $ rejoinHostsAsUser "root" [m0] ms
      usend relayer (self, nid0, pingServerLabel, "6")
      _ <- receiveWait [ matchIf (== "6") return ]
      expectLog [nid1] (== show self)

      say "SUCCESS!"
      gatherTraces
