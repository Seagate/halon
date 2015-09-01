--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This test exhibits starting a simple cluster over two nodes and controlling
-- it with `halonctl`.
--
-- We start two instances of `halond` on two nodes. We then boostrap a node
-- agent on each of these nodes, and a tracking station on one of them. Finally,
-- we contact the tracking station to request that the Dummy service be started
-- on the satellite node.
--

import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode_
  , redirectLogsHere
  , copyLog
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )

import Control.Distributed.Process (getSelfPid, say)
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

      say "Running a remote test command ..."
      systemThere ms ("echo can run a remote command")

      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nid0 <- spawnNode_ m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nid1 <- spawnNode_ m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      say $ "Redirecting logs from " ++ show nid0 ++ " ..."
      redirectLogsHere nid0
      say $ "Redirecting logs from " ++ show nid1 ++ " ..."
      redirectLogsHere nid1

      say "Spawning tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station" ++ " 2>&1"
                     )

      expectLog [nid0] (isInfixOf "New replica started in legislature://0")

      say "Starting satellite nodes ..."
      -- this runs on one node but it should control both nodes (?)
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " -a " ++ m1loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc ++ " 2>&1")
      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m0loc)
      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m1loc)
      expectLog [nid0, nid1] (isInfixOf "Node succesfully joined the cluster.")

      say "Starting dummy service ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m1loc
                     ++ " service dummy start -t " ++ m0loc ++ " 2>&1")
      expectLog [nid1] (isInfixOf "Starting service dummy")
      expectLog [nid1] (isInfixOf "Hello World!")
