--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
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
      nh1  <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      let nid1 = handleGetNodeId nh1

      say "Spawning the tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")

      say "Starting satellite node ..."
      systemThere [m1] ("./halonctl"
                     ++ " -l " ++ halonctlloc m1
                     ++ " -a " ++ m1loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc)
      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m1loc)
      expectLog [nid1] (isInfixOf "Node succesfully joined the cluster.")


      say "Starting dummy service ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m1loc
                     ++ " service dummy start -t " ++ m0loc)
      expectLog [nid0] (isInfixOf "started dummy service")
      expectLog [nid1] (isInfixOf "Hello World!")

      say "Killing satellite ..."
      whereisRemoteAsync nid1 $ serviceLabel $ serviceName Dummy.dummy
      WhereIsReply _ (Just _) <- expect
      systemThere [m1] "pkill halond; true"
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh1

      say "sending service failed"
      False <- expectTimeoutLog 1000000 [nid0]
                                (isInfixOf "started dummy service")

      -- Restart the satellite and wait for the RC to ack the service restart.
      say "Restart satellite ..."
      _ <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      expectLog [nid0] (isInfixOf "started dummy service")
