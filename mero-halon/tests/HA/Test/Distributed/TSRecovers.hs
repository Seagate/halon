-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
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
module HA.Test.Distributed.TSRecovers where

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
import Data.List (isInfixOf, isSuffixOf)

import Network.Transport (closeTransport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Test.Framework (withLocalNode, getBuildPath)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase)
import System.FilePath ((</>))
import System.Timeout (timeout)

import HA.Test.Distributed.Helpers

test :: TestTree
test = testCase "TSRecovers" $
  (>>= maybe (error "test timed out") return) $ timeout (6 * 60 * 1000000) $
  getHostAddress >>= \ip ->
  IO.bracket (do Right nt <- createTransport ip "0" defaultTCPParameters
                 return nt
             ) closeTransport $ \nt ->
  withLocalNode nt (__remoteTable initRemoteTable) $ \n0 -> do
    cp <- getProvider
    buildPath <- getBuildPath

    withHostNames cp 3 $  \ms@[m0, m1, m2] ->
     runProcess n0 $ do
      let m0loc = m0 ++ ":9000"
          m1loc = m1 ++ ":9000"
          m2loc = m2 ++ ":9000"
          halonctlloc = (++ ":0")

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond")
                               ]
      copyMeroLibs "localhost" ms
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
      waitForRCAndSubscribe [nid0, nid1]

      say "Starting satellite node ..."
      systemThere [m2] ("./halonctl"
                     ++ " -l " ++ halonctlloc m2
                     ++ " -a " ++ m2loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc
                     ++ " -t " ++ m1loc
                     )
      let tsNodes = [nid0, nid1]
      Just _ <- waitForNewNode nid2 20000000

      say "Starting ping service ..."
      systemThere [m0] $ "./halonctl"
          ++ " -l " ++ halonctlloc m0
          ++ " -a " ++ m2loc
          ++ " service ping start -t " ++ m0loc ++ " 2>&1"
      expectLog [nid2] (isInfixOf pingStartedLine)

      whereisRemoteAsync nid2 $ serviceLabel Ping.ping
      WhereIsReply _ (Just pingPid) <- expect
      send pingPid $! Ping.DummyEvent "0"
      expectLog tsNodes $ isInfixOf "received DummyEvent 0"

      forM_ (zip [1,3..] [m0, m1]) $ \(i, m) -> do
        say $ "Isolating ts node " ++ m ++ " ..."
        liftIO $ isolateHostsAsUser "root" [m] ms
        send pingPid $ show (i :: Int)
        -- TS shouldn't be able to process the event
        False <- expectTimeoutLog 1000000 tsNodes $ isSuffixOf $
          "received DummyEvent " ++ show i

        say $ "Rejoining ts node " ++ m ++ " ..."
        liftIO $ rejoinHostsAsUser "root" [m] ms
        send pingPid $ show (i + 1)
        expectLog tsNodes $ isSuffixOf $ "received DummyEvent " ++ show (i + 1)
