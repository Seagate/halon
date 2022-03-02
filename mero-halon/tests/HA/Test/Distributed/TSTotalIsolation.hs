-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Tests that the tracking station recovers when all replicas are isolated and
-- then a quorum is recovered.
--
-- * Start a satellite and three tracking station nodes.
-- * Isolate all TS nodes.
-- * Wait for a while so leader leases expire.
-- * Re-enabled communications of two TS nodes.
--
module HA.Test.Distributed.TSTotalIsolation where

import qualified Control.Exception as IO (bracket)
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
  , runProcess
  )

import Control.Monad
import Data.Function (fix)
import Data.List (isInfixOf)

import Network.Transport (closeTransport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Test.Framework (withLocalNode, getBuildPath)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase)
import System.FilePath ((</>))
import System.Timeout (timeout)

import HA.Test.Distributed.Helpers

test :: TestTree
test = testCase "TSTotalIsolation" $
  (>>= maybe (error "test timed out") return) $ timeout (6 * 60 * 1000000) $
  getHostAddress >>= \ip ->
  IO.bracket (do Right nt <- createTransport ip "0" defaultTCPParameters
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
          halonctlloc = (++ ":0")

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond")
                               ]
      copyMeroLibs "localhost" ms
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
      waitForRCAndSubscribe [nid0, nid1, nid2]

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
      Just _ <- waitForNewNode nid3 20000000

      say "Starting ping service ..."
      systemThere [m0] $ "./halonctl"
          ++ " -l " ++ halonctlloc m0
          ++ " -a " ++ m3loc
          ++ " service ping start -t " ++ m0loc ++ " 2>&1"
      expectLog [nid3] (isInfixOf pingStartedLine)

      whereisRemoteAsync nid3 $ serviceLabel Ping.ping
      WhereIsReply _ (Just pingPid) <- expect
      send pingPid $! Ping.DummyEvent "0"
      expectLog tsNodes $ isInfixOf "received DummyEvent 0"

      forM_ [m0, m1, m2] $ \m -> do
        say $ "Isolating ts node " ++ m ++ " ..."
        liftIO $ isolateHostsAsUser "root" [m] ms

      expectLog tsNodes $ isInfixOf "RS: RC died"
      send pingPid $! Ping.DummyEvent "1"
      -- TS shouldn't be able to process the event
      False <- expectTimeoutLog 1000000 tsNodes $ isInfixOf $
        "received DummyEvent 1"

      forM_ [m0, m1] $ \m -> do
        say $ "Rejoining ts node " ++ m ++ " ..."
        liftIO $ rejoinHostsAsUser "root" [m] ms

      send pingPid $! Ping.DummyEvent "2"
      expectLog tsNodes $ isInfixOf "received DummyEvent 2"
