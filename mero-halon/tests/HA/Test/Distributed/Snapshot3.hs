{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
module HA.Test.Distributed.Snapshot3 where

import qualified Control.Exception as IO (bracket)
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode
  , spawnNode_
  , copyLog
  -- , expectLog
  , __remoteTable
  , handleGetNodeId
  , handleGetInput
  )
import Control.Distributed.Commands (waitForCommand_)
import Control.Distributed.Commands.Providers (getProvider, getHostAddress)

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , runProcess
  )
import Control.Distributed.Process.Internal.Primitives (SayMessage(..))

import Control.Monad
import Data.List (isInfixOf, isPrefixOf)

import Network.Transport (closeTransport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Test.Framework (withLocalNode, getBuildPath)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Framework (assert)

import HA.Test.Distributed.Helpers

test :: TestTree
test = testCase "Snapshot3" $
  (>>= maybe (error "test timed out") return) $ timeout (60 * 1000000) $
  getHostAddress >>= \ip ->
  IO.bracket (do Right nt <- createTransport ip "0" defaultTCPParameters
                 return nt
             ) closeTransport $ \nt ->
  withLocalNode nt (__remoteTable initRemoteTable) $ \n0 -> do
    cp <- getProvider
    buildPath <- getBuildPath

    withHostNames cp 2 $ \ms@[m0, m1] ->
     runProcess n0 $ do
      let halonctlloc = (++ ":0")

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond")
                               ]
      copyMeroLibs "localhost" ms

      getSelfPid >>= copyLog (\(SayMessage _ _ msg) -> any (`isInfixOf` msg)
                                  [ "New replica started in"
                                  , "Starting service"
                                  , "Log size of replica"
                                  , "Log size when trimming"
                                  , "Noisy ping count"
                                  ]
                             )

      say "Spawning halond ..."
      [nh0, nh1] <- forM ms $ \m ->
        spawnNode m ("./halond -l " ++ m ++ ":9000 2>&1")

      let nid0 = handleGetNodeId nh0
          nid1 = handleGetNodeId nh1

      say "Spawning tracking station ..."
      let snapshotThreshold = 10 :: Int
      systemThere [m1] ("./halonctl"
                     ++ " -l " ++ halonctlloc m1
                     ++ " -a " ++ m1 ++ ":9000 bootstrap"
                     ++ " station -n " ++ show snapshotThreshold ++ " 2>&1"
                       )
      say "Waiting for RC to start ..."
      waitForRCAndSubscribe [nid1]

      say "Spawning satellites ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0 ++ ":9000 bootstrap satellite "
                     ++ "-t " ++ m1 ++ ":9000 2>&1"
                       )

      say $ "nid0 -> " ++ show nid0 ++ " nid1 -> " ++ show nid1
      Just _ <- waitForNewNode nid0 20000000

      say "Starting noisy service ..."
      let noisy_messages = snapshotThreshold * 3 :: Int
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0 ++ ":9000"
                     ++ " service noisy start" ++ " -t " ++ m1 ++ ":9000"
                     ++ " -n " ++ show noisy_messages ++ " 2>&1"
                       )

      -- expectLog [nid0] (isInfixOf "[Service:noisy] starting at")
      say "Checking log size..."
      logSizes <- replicateM 3 $ expectLogInt [nid1] "Log size when trimming: "
      say "Checking waiting for messages ..."
      noisyCounts <- replicateM (noisy_messages `div` 2) $
          expectLogInt [nid1] "Recovery Coordinator: Noisy ping count: "

      say "Checking that log size is bounded ..."
      assert $ all (<= 2 * snapshotThreshold + 1) logSizes

      say "Restarting the tracking station ..."
      systemThere [m1] "pkill halond; true"
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh1

      say "Respawning halond ..."
      nid1' <- spawnNode_ m1 ("./halond -l " ++ m1 ++ ":9000 2>&1")

      say "Waiting for RC to restart ..."
      logSize <- expectLogInt [nid1'] "Log size of replica: "
      noisyCount <- expectLogInt [nid1'] "Recovery Coordinator: Noisy ping count: "

      say "Checking that log size is bounded ..."
      assert $ logSize <= snapshotThreshold * 2 + 1
      say "Checking that ping counts were preserved ..."
      assert $ noisyCount >= maximum noisyCounts

  where
    expectLogInt :: [NodeId] -> String -> Process Int
    expectLogInt nids pfx = receiveWait
       [ matchIf (\(SayMessage _ pid msg) -> elem (processNodeId pid) nids &&
                                    pfx `isPrefixOf` msg) $
                 \(SayMessage _ _ msg) -> return $ read $ drop (length pfx) msg
       ]
