-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Tests that the RC successfully restarts all running services on
-- a cluster after a restart.
--
module HA.Test.Distributed.ClusterDeath where

import qualified Control.Exception as IO (bracket)
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , handleGetInput
  , handleGetNodeId
  , systemThere
  , spawnNode
  , spawnNode_
  , copyLog
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands (waitForCommand_)
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , runProcess
  )

import Data.Function (fix)
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
test = testCase "ClusterDeath" $
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
      nh0 <- spawnNode m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nh1 <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      let nid0 = handleGetNodeId nh0
          nid1 = handleGetNodeId nh1

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
      _ <- waitForNewNode nid1 20000000

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

      say "Killing cluster ..."
      systemThere ms "pkill halond; true"
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh0
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh1

      -- Restart the satellite and wait for the RC to ack the service restart.
      say "Restart cluster ..."
      nid0' <- spawnNode_ m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      waitForRCAndSubscribe [nid0']
      nid1' <- spawnNode_ m1 ("./halond -l " ++ m1loc ++ " 2>&1")

      -- Wait until the dummy service is registered.
      fix $ \loop -> do
        whereisRemoteAsync nid1' "service.dummy"
        WhereIsReply "service.dummy" m <- expect
        maybe (receiveTimeout 10000 [] >> loop) (const $ return ()) m

      expectLog [nid1'] (isInfixOf dummyStartedLine)
