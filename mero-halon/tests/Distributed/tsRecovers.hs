--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Tests that the cluster proceeds after the tracking station recovers
-- quorum.
--
-- * Start a satellite and two tracking station nodes.
-- * Start the noisy service in the satellite.
-- * Isolate a tracking station node so it cannot communicate with any other node.
-- * Re-enable communications of the TS node.
-- * Wait until the TS process events.
-- * Isolate another TS node.
-- * Re-enable communications of the TS node.
-- * Wait until the TS process events.
--

import Control.Concurrent (forkIO)
import Control.Distributed.Commands.IPTables
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process hiding (withHostNames)
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )
import HA.Service hiding (__remoteTable)
import qualified HA.Services.Ping as Ping

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )

import Control.Monad
import Data.Function (fix)
import Data.List (isInfixOf)

import Network.Transport.TCP (createTransport, defaultTCPParameters)

import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeDirectory)
import System.IO
import System.Timeout (timeout)


getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main = (>>= maybe (error "test timed out") return) $
       timeout (6 * 60 * 1000000) $ do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    cp <- getProvider

    buildPath <- getBuildPath

    ip <- getHostAddress
    Right nt <- createTransport ip "4000" defaultTCPParameters
    n0 <- newLocalNode nt (__remoteTable initRemoteTable)

    withHostNames cp 3 $  \ms@[m0, m1, m2] ->
     runProcess n0 $ do
      let m0loc = m0 ++ ":9000"
          m1loc = m1 ++ ":9000"
          m2loc = m2 ++ ":9000"
          halonctlloc = (++ ":9001")

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]
      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nhs <- forM (zip ms [m0loc, m1loc, m2loc]) $ \(m, mloc) ->
               spawnNode m ("./halond -l " ++ mloc ++ " 2>&1")
      let [nid0, nid1, nid2] = map handleGetNodeId nhs
      forM_ nhs $ \nh -> liftIO $ forkIO $ fix $ \loop -> do
        e <- handleGetInput nh
        case e of
          Left rc -> putStrLn $ show (handleGetNodeId nh) ++ ": terminated " ++ show rc
          Right s -> putStrLn (show (handleGetNodeId nh) ++ ": " ++ s) >> loop
      say $ "Redirecting logs ..."
      redirectLogsHere nid0
      redirectLogsHere nid1
      redirectLogsHere nid2
      -- redirectLogsHere nid3

      say "Spawning the tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " -a " ++ m1loc
                     ++ " bootstrap station"
                     ++ " -r 2000000"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")
      expectLog [nid1] (isInfixOf "New replica started in legislature://0")
      expectLog [nid0, nid1] (isInfixOf "Starting from empty graph.")

      say "Starting satellite node ..."
      systemThere [m2] ("./halonctl"
                     ++ " -l " ++ halonctlloc m2
                     ++ " -a " ++ m2loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc
                     ++ " -t " ++ m1loc
                     )
      let tsNodes = [nid0, nid1]
      expectLog tsNodes $ isInfixOf $ "New node contacted: nid://" ++ m2loc
      expectLog [nid2] (isInfixOf "Got UpdateEQNodes")

      say "Starting ping service ..."
      systemThere [m0] $ "./halonctl"
          ++ " -l " ++ halonctlloc m0
          ++ " -a " ++ m2loc
          ++ " service ping start -t " ++ m0loc ++ " 2>&1"
      expectLog tsNodes (isInfixOf "started ping service")

      whereisRemoteAsync nid2 $ serviceLabel $ serviceName Ping.ping
      WhereIsReply _ (Just pingPid) <- expect
      send pingPid "0"
      expectLog tsNodes $ isInfixOf "received DummyEvent 0"

      forM_ (zip [1,3..] [m0, m1]) $ \(i, m) -> do
        say $ "Isolating ts node " ++ m ++ " ..."
        liftIO $ isolateHostsAsUser "root" [m] ms
        send pingPid $ show (i :: Int)
        -- TS shouldn't be able to process the event
        False <- expectTimeoutLog 1000000 tsNodes $ isInfixOf $
          "received DummyEvent " ++ show i

        say $ "Rejoining ts node " ++ m ++ " ..."
        liftIO $ rejoinHostsAsUser "root" [m] ms
        send pingPid $ show (i + 1)
        expectLog tsNodes $ isInfixOf $ "received DummyEvent " ++ show (i + 1)
