{-# LANGUAGE ScopedTypeVariables #-}
--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
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
  , __remoteTable
  , handleGetNodeId
  , handleGetInput
  )
import Control.Distributed.Commands (waitForCommand_)
import Control.Distributed.Commands.Providers (getProvider, getHostAddress)

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )

import Control.Monad
import Data.List (isInfixOf, isPrefixOf)

import Network.Transport.TCP (createTransport, defaultTCPParameters)

import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeDirectory)
import Test.Framework (assert)


getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main = do
    cp <- getProvider
    buildPath <- getBuildPath
    ip <- getHostAddress
    Right nt <- createTransport ip "4000" defaultTCPParameters
    let remoteTable = __remoteTable initRemoteTable
    n0 <- newLocalNode nt remoteTable

    withHostNames cp 2 $ \ms@[m0, m1] ->
     runProcess n0 $ do

      -- Time out after a while so CI can still make progress.
      self <- getSelfPid
      _ <- spawnLocal $ do
             _ <- expectTimeout (60 * 1000000) :: Process (Maybe ())
             kill self "test timed out"

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]

      getSelfPid >>= copyLog (\(_, _, msg) -> any (`isInfixOf` msg)
                                  [ "New replica started in"
                                  , "New node contacted"
                                  , "Starting service"
                                  , "Log size of replica"
                                  , "Log size when trimming"
                                  , "Noisy ping count"
                                  ]
                             )

      say "Spawning halond ..."
      [nh0, nh1] <- forM ms $ \m -> do
          n <- spawnNode m ("./halond -l " ++ m ++ ":9000 2>&1")
          redirectLogsHere $ handleGetNodeId n
          return n

      let nid0 = handleGetNodeId nh0
          nid1 = handleGetNodeId nh1

      say "Spawning satellites ..."
      systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000 bootstrap satellite "
                        ++ "-t " ++ m1 ++ ":9000 2>&1"
                       )

      say "Spawning tracking station ..."
      let snapshotThreshold = 10 :: Int
      systemThere [m1] ("./halonctl -a " ++ m1 ++ ":9000 bootstrap" ++
                        " station -n " ++ show snapshotThreshold ++ " 2>&1"
                       )

      say "Waiting for RC to start ..."
      say $ "nid0 -> " ++ show nid0 ++ " nid1 -> " ++ show nid1
      expectLog [nid1] (isInfixOf $ "New node contacted: " ++ show nid0)

      say "Starting noisy service ..."
      let noisy_messages = 30 :: Int
      systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000" ++
                        " service noisy start" ++ " -t " ++ m1 ++ ":9000" ++
                        " -n " ++ show noisy_messages ++ " 2>&1"
                       )

      expectLog [nid0] (isInfixOf "Starting service noisy")
      logSizes <- replicateM 5 $ expectLogInt [nid1] "Log size when trimming: "
      noisyCounts <- replicateM (noisy_messages `div` 2) $
          expectLogInt [nid1] "Recovery Coordinator: Noisy ping count: "

      say "Checking that log size is bounded ..."
      assert $ all (<= 21) logSizes

      say "Restarting the tracking station ..."
      systemThere [m1] "pkill halond; true"
      _ <- liftIO $ waitForCommand_ $ handleGetInput nh1

      nid1' <- spawnNode_ m1 ("./halond -l " ++ m1 ++ ":9000 2>&1")
      redirectLogsHere nid1'
      systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000 bootstrap satellite "
                        ++ "-t " ++ m1 ++ ":9000 2>&1"
                       )

      systemThere [m1] ("./halonctl -a " ++ m1 ++ ":9000 bootstrap" ++
                        " station -n " ++
                        show snapshotThreshold ++ " 2>&1"
                       )
      logSize <- expectLogInt [nid1'] "Log size of replica: "
      noisyCount <- expectLogInt [nid1'] "Recovery Coordinator: Noisy ping count: "

      say "Checking that log size is bounded ..."
      assert $ logSize <= 21
      say "Checking that ping counts were preserved ..."
      assert $ noisyCount >= maximum noisyCounts

  where
    expectLogInt :: [NodeId] -> String -> Process Int
    expectLogInt nids pfx = receiveWait
       [ matchIf (\(_, pid, msg) -> elem (processNodeId pid) nids &&
                                    pfx `isPrefixOf` msg) $
                 \(_ :: String, _, msg) -> return $ read $ drop (length pfx) msg
       ]
