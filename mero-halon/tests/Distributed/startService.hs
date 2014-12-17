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
  , spawnNode
  , redirectLogsHere
  , copyLog
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers (getProvider)

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
import System.Process (readProcess)

getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main = do
    cp <- getProvider

    buildPath <- getBuildPath

    [ip] <- fmap (take 1 . lines) $ readProcess "hostname" ["-i"] ""
    Right nt <- createTransport ip "4000" defaultTCPParameters
    n0 <- newLocalNode nt (__remoteTable initRemoteTable)

    withHostNames cp 2 $  \ms@[m0, m1] ->
     runProcess n0 $ do

      say "Copying binaries ..."
      -- test copying a folder
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]

      say "Running a remote test command ..."
      systemThere ms ("echo can run a remote command")

      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nid0 <- spawnNode m0 ("./halond -l " ++ m0 ++ ":9000 2>&1")
      nid1 <- spawnNode m1 ("./halond -l " ++ m1 ++ ":9000 2>&1")
      say $ "Redirecting logs from " ++ show nid0 ++ " ..."
      redirectLogsHere nid0
      say $ "Redirecting logs from " ++ show nid1 ++ " ..."
      redirectLogsHere nid1

      say "Spawning node agents ..."
      systemThere ms ("./halonctl -a $(hostname -I | head -1 | tr -d ' '):9000 bootstrap satellite")
      expectLog [nid0] (isInfixOf "Starting service HA.NodeAgent")
      expectLog [nid1] (isInfixOf "Starting service HA.NodeAgent")
      say "Spawning tracking station ..."
      systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000 bootstrap" ++
                        " station -t " ++ m0 ++ ":9000 -s " ++ m1 ++ ":9000")
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")
      say "Starting dummy service ..."
      expectLog [nid0] (isInfixOf "New node contacted")
      systemThere [m0] ("./halonctl -a " ++ m1 ++ ":9000" ++
                        " service dummy start -t " ++ m0 ++ ":9000")
      expectLog [nid1] (isInfixOf "Starting service dummy")
