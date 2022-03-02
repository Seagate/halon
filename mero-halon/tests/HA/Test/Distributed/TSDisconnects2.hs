-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Tests that tracking station failures allow the cluster to proceed.
--
-- * Start a satellite and three tracking station nodes.
-- * Start the noisy service in the satellite.
-- * Kill a tracking station node.
-- * Wait for the RC to report events produced by the service.
-- * Restart the tracking station node.
-- * Kill another TS node.
-- * Wait for the RC to report events produced by the service.
-- * Restart the TS node.
-- * Kill another TS node.
-- * Wait for the RC to report events produced by the service.
--
module HA.Test.Distributed.TSDisconnects2 where

import qualified Control.Exception as IO (bracket)
import Control.Distributed.Commands (waitForCommand_)
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
test = testCase "TSDisconnects2" $
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
                      ++ " service ping start"
                      ++ " -t " ++ m0loc
                      ++ " -t " ++ m1loc
                      ++ " -t " ++ m2loc
                      ++ " 2>&1"
      expectLog [nid3] (isInfixOf pingStartedLine)

      whereisRemoteAsync nid3 $ serviceLabel Ping.ping
      WhereIsReply _ (Just pingPid) <- expect
      say "Testing ping service ..."
      send pingPid $! Ping.DummyEvent "0"
      expectLog tsNodes $ isInfixOf "received DummyEvent 0"

      forM_ (zip3 [1,3..] [m0, m1, m2] nhs) $ \(i, m, nh) -> do
        say $ "killing ts node " ++ m ++ " ..."
        systemThere [m] "pkill halond; true"
        _ <- liftIO $ waitForCommand_ $ handleGetInput nh
        send pingPid $! Ping.DummyEvent (show (i :: Int))
        expectLog tsNodes $ isSuffixOf $ "received DummyEvent " ++ show i

        say $ "Restarting ts node " ++ m ++ " ..."
        _ <- spawnNode_ m ("./halond -l " ++ m ++ ":9000" ++ " 2>&1")
        send pingPid $! Ping.DummyEvent (show (i + 1 :: Int))
        expectLog tsNodes $ isSuffixOf $ "received DummyEvent " ++ show (i + 1)
