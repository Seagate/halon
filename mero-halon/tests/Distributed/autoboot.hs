--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This test exhibits starting a tracking station, killing the `halond`
-- process, restarting it and verifying that the tracking station is
-- also restarted through autoboot.
--

import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode
  , spawnNode_
  , redirectLogsHere
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
  , newLocalNode
  , runProcess
  )

import Data.List (isInfixOf)

import Network.Transport.TCP (createTransport, defaultTCPParameters)

import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeDirectory)
import System.Timeout


getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main =
  (>>= maybe (error "test timed out") return) $ timeout (120 * 1000000) $ do
    cp <- getProvider

    buildPath <- getBuildPath

    ip <- getHostAddress
    Right nt <- createTransport ip "4000" defaultTCPParameters
    n0 <- newLocalNode nt (__remoteTable initRemoteTable)

    withHostNames cp 2 $  \ms@[m0, m1] ->
     runProcess n0 $ do
      let m0loc = m0 ++ ":9000"
          m1loc = m1 ++ ":9000"
          halonctlloc = (++ ":9001")

      say "Copying binaries ..."
      -- test copying a folder
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]

      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nh0 <- spawnNode m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nh1 <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      let nid0 = handleGetNodeId nh0
          nid1 = handleGetNodeId nh1
      say $ "Redirecting logs from " ++ show [nid0, nid1] ++ " ..."
      redirectLogsHere nid0
      redirectLogsHere nid1

      say "Spawning tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " -a " ++ m1loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0, nid1] (isInfixOf "Recovery Coordinator: New node contacted:")

      say "Killing halond"
      systemThere ms "pkill halond; true"
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh0
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh1

      say "Restarting halond"
      nid0' <- spawnNode_ m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nid1' <- spawnNode_ m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      redirectLogsHere nid0'
      redirectLogsHere nid1'
      expectLog [nid0', nid1'] (isInfixOf "Found existing graph")
