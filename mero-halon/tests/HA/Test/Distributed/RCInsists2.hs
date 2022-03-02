-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Tests that RC insist in restarting the service if it cannot contact the
-- satellite
--
-- * Start a satellite and a tracking station node.
-- * Start a service in the satellite.
-- * Kill the satellite.
-- * Send a ServiceFailed message to the RC.
-- * Wait for the RC to retry starting the service a few times.
-- * Restart the satellite.
-- * Wait for the RC to get the ServiceStarted message
--
module HA.Test.Distributed.RCInsists2 where

import qualified Control.Exception as IO (bracket)
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode
  , spawnNode_
  , copyLog
  , expectLog
  , expectTimeoutLog
  , __remoteTable
  , handleGetNodeId
  , handleGetInput
  )
import Control.Distributed.Commands (waitForCommand_)
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )
import HA.Service hiding (__remoteTable)
import qualified HA.Services.Dummy as Dummy

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , runProcess
  )

import Data.List (isInfixOf)

import Network.Transport (closeTransport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Test.Framework (withLocalNode, getBuildPath)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase)
import System.FilePath ((</>))
import System.Timeout

import HA.EventQueue.Producer
import HA.Test.Distributed.Helpers
import HA.Resources.HalonVars

fastReconnectVars :: HalonVars
fastReconnectVars = defaultHalonVars { _hv_recovery_max_retries = (-30) }

test :: TestTree
test = testCase "RCInsists2" $
  (>>= maybe (error "test timed out") return) $ timeout (120 * 1000000) $
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
      nh1  <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      let nid1 = handleGetNodeId nh1

      say "Spawning the tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")
      waitForRCAndSubscribe [nid0]

      say "Starting satellite node ..."
      systemThere [m1] ("./halonctl"
                     ++ " -l " ++ halonctlloc m1
                     ++ " -a " ++ m1loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc)

      Just _ <- waitForNewNode nid1 20000000

      -- By default halond tries to search for the failed nodes
      -- once per minute, this makes test run really slow and timeout on a slow
      -- CI. So we setup a new options that will query new node once per 10s.
      promulgateEQ_ [nid0] $ SetHalonVars fastReconnectVars

      say "Starting dummy service ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m1loc
                     ++ " service dummy start -t " ++ m0loc)
      expectLog [nid1] (isInfixOf dummyStartedLine)
      expectLog [nid1] (isInfixOf "Hello World!")

      say "Killing satellite ..."
      whereisRemoteAsync nid1 $ serviceLabel Dummy.dummy
      WhereIsReply _ (Just _) <- expect
      systemThere [m1] "pkill halond; true"
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh1

      say "sending service failed"
      False <- expectTimeoutLog 1000000 [nid0]
                                (isInfixOf dummyStartedLine)

      -- Restart the satellite and wait for the RC to ack the service restart.
      say "Restart satellite ..."
      _ <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      expectLog [nid1] (isInfixOf dummyStartedLine)
