-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This test exhibits starting a simple cluster over two nodes and stressing the
-- RC with many events.
--
-- We start two instances of `halond` on two nodes. We then start the TS in one
-- of them and a satellite in the other. Then we start the ping service and send
-- many pings.
--
module HA.Test.Distributed.StressRC where

import qualified Control.Exception as IO (bracket)
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode_
  , copyLog
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , runProcess
  )

import Control.Monad(forM_)
import Data.List (isInfixOf, isSuffixOf)
import HA.Service hiding (__remoteTable)
import qualified HA.Services.Ping as Ping

import Network.Transport (closeTransport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Test.Framework (withLocalNode, getBuildPath)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase)
import System.FilePath ((</>))
import System.IO
import System.Timeout

import HA.Test.Distributed.Helpers

testTrace :: String -> Process ()
testTrace m = do
    self <- getSelfPid
    liftIO $ hPutStrLn stderr $ show self ++ ": [test] " ++ m

test :: TestTree
test = testCase "StressRC" $
  (>>= maybe (error "test timed out") return) $ timeout (360 * 1000000) $
  getHostAddress >>= \ip ->
  IO.bracket (do Right nt <- createTransport ip "0" defaultTCPParameters
                 return nt
             ) closeTransport $ \nt ->
  withLocalNode nt (__remoteTable initRemoteTable) $ \n0 -> do
    cp <- getProvider
    buildPath <- getBuildPath

    withHostNames cp 2 $  \ms@[m0, m1] ->
     runProcess n0 $ do
      let m0loc = m0 ++ ":9000"
          m1loc = m1 ++ ":9000"
          halonctlloc = (++ ":0")

      say "Copying binaries ..."
      -- test copying a folder
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond")
                               ]
      copyMeroLibs "localhost" ms

      say "Running a remote test command ..."
      systemThere ms ("echo can run a remote command")

      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nid0 <- spawnNode_ m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nid1 <- spawnNode_ m1 ("./halond -l " ++ m1loc ++ " 2>&1")

      say "Spawning tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station" ++ " 2>&1"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")
      waitForRCAndSubscribe [nid0]

      say "Starting satellite nodes ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m1loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc ++ " 2>&1")
      Just _ <- waitForNewNode nid1 20000000

      say "Starting ping service ..."
      systemThere [m0] $ "./halonctl"
          ++ " -l " ++ halonctlloc m0
          ++ " -a " ++ m1loc
          ++ " service ping start -t " ++ m0loc ++ " 2>&1"
      expectLog [nid1] (isInfixOf pingStartedLine)

      say "Where is ..."
      whereisRemoteAsync nid1 $ serviceLabel Ping.ping
      WhereIsReply _ (Just pingPid) <- expect
      say "Sending a test ping ..."
      send pingPid $! Ping.DummyEvent "0"
      expectLog [nid0] $ isSuffixOf "received DummyEvent 0"

      let numPings = 500 :: Int
      say $ "Sending " ++ show numPings ++ " pings ..."
      forM_ [1..numPings] $ send pingPid . Ping.DummyEvent . show
      send pingPid (Ping.SyncPing "final")

      forM_ [1..numPings] $ \i -> do
        expectLog [nid0] $ isSuffixOf $ "received DummyEvent " ++ show i
        testTrace $ "Found event " ++ show i
      expectLog [nid0] $ isSuffixOf "received SyncPing final"
      testTrace "SUCCESS!"
