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
  , spawnNode_
  , redirectLogsHere
  , copyLog
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers (getProvider, getHostAddress)

import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )

import Control.Monad (forM, replicateM_, replicateM)
import Data.List (isInfixOf, isPrefixOf)

import Network.Transport.TCP (createTransport, defaultTCPParameters)

import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeDirectory)

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

    withHostNames cp 2 $ \ms@(m0: mss) ->
     runProcess n0 $ do
      let halonctlloc = (++ ":9001")

      say "Copying binaries ..."
      -- test copying a folder
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]

      getSelfPid >>= copyLog (\(_, _, msg) -> any (`isInfixOf` msg)
                                  [ "New replica started in"
                                  , "New node contacted"
                                  , "Starting service"
                                  , "Log size when trimming"
                                  ]
                             )

      say "Spawning halond ..."
      (nid0 : nidss) <- forM ms $ \m -> do
                n <- spawnNode_ m ("./halond -l " ++ m ++ ":9000 2>&1")
                redirectLogsHere n
                return n

      say "Spawning satellites ..."
      systemThere [m0] ("./halonctl"
                        ++ " -l " ++ halonctlloc m0
                        ++ " -a " ++ m0 ++ ":9000 bootstrap"
                        ++ " satellite"
                        ++ concatMap ((" -t " ++) . (++ ":9000")) mss
                        ++ " 2>&1"
                       )

      say "Spawning tracking station ..."
      systemThere [m0] ("./halonctl"
                        ++ " -l " ++ halonctlloc m0
                        ++ concatMap ((" -a " ++) . (++ ":9000")) mss
                        ++ " bootstrap station -n 100 2>&1"
                       )

      say "Waiting acks ..."
      replicateM_ (length mss) $
        expectLog nidss (isInfixOf "New replica started in legislature://0")
      expectLog nidss (isInfixOf "New node contacted")

      say "Starting noisy service ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ " -a " ++ m0 ++ ":9000"
                     ++ " service noisy start"
                     ++ concatMap ((" -t " ++) . (++ ":9000")) mss
                        ++ " -n 10000 2>&1"
                       )
      expectLog [nid0] (isInfixOf "Starting service noisy")
      say "Log size every 100 mesages:"
      replicateM 100 expectLogSize >>= say . show

  where
    expectLogSize :: Process Int
    expectLogSize = do
      (_, _, msg) <- expect :: Process (String, ProcessId, String)
      let pfx = "Log size when trimming: "
      if pfx `isPrefixOf` msg then return $ read $ drop (length pfx) msg
        else expectLogSize
