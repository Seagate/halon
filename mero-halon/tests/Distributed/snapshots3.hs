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
  , redirectLogsHere
  , copyLog
  , expectLog
  , expectTimeoutLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers (getProvider, getHostAddress)

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )

import Control.Monad
import Data.List (isInfixOf, isPrefixOf)

import HA.EventQueue.Producer (promulgateEQ)
import HA.Resources (Node(..))
import HA.Service (ServiceFailed(..), encodeP, serviceName, serviceLabel)
import qualified HA.Services.Dummy as Dummy

import Network.Transport.TCP (createTransport, defaultTCPParameters)

import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeDirectory)
import Test.Framework (assert)


import Debug.Trace

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

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]

      getSelfPid >>= copyLog (\(_,_,msg) -> trace ("COPYLOG <<<<<< " ++ msg) True)
      -- getSelfPid >>= copyLog (\(_, _, msg) -> any (`isInfixOf` msg)
      --                             [ "New replica started in"
      --                             , "New node contacted"
      --                             , "Starting service"
      --                             , "Log size of replica"
      --                             , "Log size when trimming"
      --                             , "Noisy ping count"
      --                             ]
      --                        )

      let m0loc = m0 ++ ":9000"
          m1loc = m1 ++ ":9000"
      say "Spawning halond ..."
      nid0 <- spawnNode m0 ("./halond -l " ++ m0loc ++ " 2>&1")
      nid1 <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      say $ "Redirecting logs from " ++ show nid0 ++ " ..."
      redirectLogsHere nid0
      say $ "Redirecting logs from " ++ show nid1 ++ " ..."
      redirectLogsHere nid1

      say "Spawning the tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")

      say "Starting satellite node ..."
      systemThere [m1] ("./halonctl"
                     ++ " -a " ++ m1loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc)
      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m1loc)
      expectLog [nid1] (isInfixOf "Got UpdateEQNodes")

      -- say "Starting dummy service ..."
      -- systemThere [m0] ("./halonctl -a " ++ m1loc ++
      --                   " service dummy start -t " ++ m0loc)

      say "Starting noisy service ..."
      let noisy_messages = 30 :: Int
      systemThere [m0] ("./halonctl -a " ++ m1loc ++
                        " service noisy start" ++ " -t " ++ m0loc ++
                        " -n " ++ show noisy_messages ++ " 2>&1"
                       )
      expectLog [nid1] (isInfixOf "Starting noisy service")
      -- expectLog [nid0] (isInfixOf "started dummy service")
      -- expectLog [nid1] (isInfixOf "Hello World!")

      -- say "Killing satellite ..."
      -- whereisRemoteAsync nid1 $ serviceLabel $ serviceName Dummy.dummy
      -- WhereIsReply _ (Just pid) <- expect
      -- systemThere [m1] "pkill halond; wait `pgrep halond`; true"
      -- say "sending service failed"
      -- _ <- promulgateEQ [nid0] . encodeP $ ServiceFailed (Node nid1) Dummy.dummy
      --                                                    pid
      -- False <- expectTimeoutLog 1000000 [nid0]
      --                           (isInfixOf "started dummy service")

      -- -- Restart the satellite and wait for the RC to ack the service restart.
      -- say "Restart satellite ..."
      -- _ <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")
      -- expectLog [nid0] (isInfixOf "started dummy service")

      -- say "Spawning halond ..."
      -- [nid0, nid1] <- forM ms $ \m -> do
      --     n <- spawnNode m ("./halond -l " ++ m ++ ":9000 2>&1")
      --     redirectLogsHere n
      --     return n

      -- say "Spawning tracking station ..."
      -- let snapshotThreshold = 10 :: Int
      -- systemThere [m1] ("./halonctl -a " ++ m1 ++ ":9000 bootstrap" ++
      --                   " station -n " ++ show snapshotThreshold ++ " 2>&1"
      --                  )

      -- say "Spawning satellites ..."
      -- systemThere [m0] ("./halonctl -a " ++ m1 ++ ":9000 bootstrap satellite "
      --                   ++ "-t " ++ m0 ++ ":9000 2>&1"
      --                  )

      -- systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000" ++
      --                   " service decision-log start" ++ " -t " ++ m1 ++ ":9000" ++
      --                   " -f /tmp/snap-log.log 2>&1")

      -- systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000" ++
      --                   " service dummy start -t " ++ m1 ++ ":9000 2>&1")

      -- expectLog [nid0] (isInfixOf "started dummy service")

      -- say "Waiting for RC to start ..."
      -- expectLog [nid1] (isInfixOf "New node contacted")

      -- say "Starting noisy service ..."
      -- let noisy_messages = 30 :: Int
      -- systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000" ++
      --                   " service noisy start" ++ " -t " ++ m1 ++ ":9000" ++
      --                   " -n " ++ show noisy_messages ++ " 2>&1"
      --                  )
      -- expectLog [nid0] (isInfixOf "Starting service noisy")
      -- logSizes <- replicateM 5 $ expectLogInt [nid1] "Log size when trimming: "
      -- noisyCounts <- replicateM (noisy_messages `div` 2) $
      --     expectLogInt [nid1] "Recovery Coordinator: Noisy ping count: "

      -- say "Checking that log size is bounded ..."
      -- assert $ all (<= 21) logSizes

      -- say "Restarting the tracking station ..."
      -- systemThere [m1] "pkill halond; wait `pgrep halond`; true"

      -- nid1' <- spawnNode m1 ("./halond -l " ++ m1 ++ ":9000 2>&1")
      -- redirectLogsHere nid1'
      -- systemThere [m0] ("./halonctl -a " ++ m0 ++ ":9000 bootstrap satellite "
      --                   ++ "-t " ++ m1 ++ ":9000 2>&1"
      --                  )

      -- systemThere [m1] ("./halonctl -a " ++ m1 ++ ":9000 bootstrap" ++
      --                   " station -n " ++
      --                   show snapshotThreshold ++ " 2>&1"
      --                  )
      -- logSize <- expectLogInt [nid1'] "Log size of replica: "
      -- noisyCount <- expectLogInt [nid1'] "Recovery Coordinator: Noisy ping count: "

      -- say "Checking that log size is bounded ..."
      -- assert $ logSize <= 21
      -- say "Checking that ping counts were preserved ..."
      -- assert $ noisyCount >= maximum noisyCounts

  where
    expectLogInt :: [NodeId] -> String -> Process Int
    expectLogInt nids pfx = receiveWait
       [ matchIf (\(_, pid, msg) -> elem (processNodeId pid) nids &&
                                    pfx `isPrefixOf` msg) $
                 \(_ :: String, _, msg) -> return $ read $ drop (length pfx) msg
       ]
