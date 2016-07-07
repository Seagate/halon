-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Tests that tracking station failures allow the cluster to proceed.
--
-- * Start a satellite and three tracking station nodes.
-- * Start the noisy service in the satellite.
-- * Isolate a tracking station node so it cannot communicate with any other node.
-- * Wait for the RC to report events produced by the service.
-- * Re-enable communications of the TS node.
-- * Isolate another TS node.
-- * Wait for the RC to report events produced by the service.
-- * Re-enable communications of the TS node.
-- * Isolate another TS node.
-- * Wait for the RC to report events produced by the service.
--
module HA.Test.Distributed.TSDisconnects where

import qualified Control.Exception as IO (bracket)
import Control.Concurrent (forkIO)
import Control.Distributed.Commands.IPTables
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode
  , NodeHandle(..)
  , copyLog
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )
import HA.Service hiding (__remoteTable)
import qualified HA.Services.Ping as Ping

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , runProcess
  )

import Control.Monad
import Data.Function (fix)
import Data.List (isInfixOf, isSuffixOf)

import Network.Transport (closeTransport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Test.Framework (withLocalNode, getBuildPath)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase)
import System.FilePath ((</>))
import System.Timeout (timeout)


test :: TestTree
test = testCase "TSDisconnects" $
  (>>= maybe (error "test timed out") return) $ timeout (6 * 60 * 1000000) $
  getHostAddress >>= \ip ->
  IO.bracket (do Right nt <- createTransport ip "4000" defaultTCPParameters
                 return nt
             ) closeTransport $ \nt ->
  withLocalNode nt (__remoteTable initRemoteTable) $ \n0 -> do
    cp <- getProvider
    buildPath <- getBuildPath

    withHostNames cp 4 $  \ms@[m0, m1, m2, m3] ->
     runProcess n0 $ do
      let m0loc = m0 ++ ":9000"
          m1loc = m1 ++ ":9000"
          m2loc = m2 ++ ":9000"
          m3loc = m3 ++ ":9000"
          halonctlloc = (++ ":9001")

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]
      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nhs <- forM (zip ms [m0loc, m1loc, m2loc, m3loc]) $ \(m, mloc) ->
               spawnNode m ("./halond -l " ++ mloc ++ " 2>&1")
      let [nid0, nid1, nid2, nid3] = map handleGetNodeId nhs
      forM_ nhs $ \nh -> liftIO $ forkIO $ fix $ \loop -> do
        e <- handleGetInput nh
        case e of
          Left rc -> putStrLn $ show (handleGetNodeId nh) ++ ": terminated " ++ show rc
          Right s -> putStrLn (show (handleGetNodeId nh) ++ ": " ++ s) >> loop

      say "Spawning the tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0loc
                     ++ " -a " ++ m1loc
                     ++ " -a " ++ m2loc
                     ++ " bootstrap station"
                     ++ " -r 2000000"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")
      expectLog [nid1] (isInfixOf "New replica started in legislature://0")
      expectLog [nid2] (isInfixOf "New replica started in legislature://0")
      expectLog [nid0, nid1, nid2] (isInfixOf "Starting from empty graph.")

      say "Starting satellite node ..."
      systemThere [m1] ("./halonctl"
                     ++ " -l " ++ halonctlloc m1
                     ++ " -a " ++ m3loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc
                     ++ " -t " ++ m1loc
                     ++ " -t " ++ m2loc
                     )
      let tsNodes = [nid0, nid1, nid2]
      expectLog tsNodes $ isInfixOf $ "New node contacted: nid://" ++ m3loc
      expectLog [nid3] (isInfixOf "Node succesfully joined the cluster.")

      say "Starting ping service ..."
      systemThere [m0] $ "./halonctl"
          ++ " -l " ++ halonctlloc m0
          ++ " -a " ++ m3loc
          ++ " service ping start -t " ++ m0loc ++ " 2>&1"
      expectLog tsNodes (isInfixOf "started ping service")

      whereisRemoteAsync nid3 $ serviceLabel $ serviceName Ping.ping
      WhereIsReply _ (Just pingPid) <- expect
      send pingPid "0"
      expectLog tsNodes $ isInfixOf "received DummyEvent 0"

      forM_ (zip [1,3..] [m0, m1, m2]) $ \(i, m) -> do
        say $ "Isolating ts node " ++ m ++ " ..."
        liftIO $ isolateHostsAsUser "root" [m] ms
        send pingPid $ show (i :: Int)
        expectLog tsNodes $ isSuffixOf $ "received DummyEvent " ++ show i

        say $ "Rejoining ts node " ++ m ++ " ..."
        liftIO $ rejoinHostsAsUser "root" [m] ms
        send pingPid $ show (i + 1)
        expectLog tsNodes $ isSuffixOf $ "received DummyEvent " ++ show (i + 1)
