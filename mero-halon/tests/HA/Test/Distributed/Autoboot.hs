-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This test exhibits starting a tracking station, killing the `halond`
-- process, restarting it and verifying that the tracking station is
-- also restarted through autoboot.
--
module HA.Test.Distributed.Autoboot where

import qualified Control.Exception as IO (bracket)
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode
  , spawnNode_
  , copyLog
  , expectLog
  , handleGetNodeId
  , handleGetInput
  , __remoteTable
  )
import Control.Distributed.Commands (waitForCommand_)
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )

import Control.Distributed.Process (getSelfPid, liftIO, say)
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

import HA.Test.Distributed.Helpers

test :: TestTree
test = testCase "Autoboot" $
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

      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nh0 <- spawnNode m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nh1 <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      let nid0 = handleGetNodeId nh0
          nid1 = handleGetNodeId nh1

      say "Spawning tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " -a " ++ m1loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0, nid1] $
        isInfixOf "Recovery Coordinator: continue in normal mode"

      say "Killing halond"
      systemThere ms "pkill halond; true"
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh0
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh1

      say "Restarting halond"
      nid0' <- spawnNode_ m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nid1' <- spawnNode_ m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      expectLog [nid0', nid1'] (isInfixOf "Found existing graph")
