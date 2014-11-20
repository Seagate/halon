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

import Control.Distributed.Commands.DigitalOcean (getCredentialsFromEnv)
import Control.Distributed.Commands.Process
  ( withHostNames
  , copyFiles
  , systemThere
  , spawnNode
  , redirectLogs
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers.DigitalOcean
  ( createProvider
  , NewDropletArgs(..)
  )

import Control.Distributed.Process (say, liftIO, getSelfPid)
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  , localNodeId
  )
import Data.Binary (encode)
import Network.Transport.TCP (createTransport, defaultTCPParameters)


main :: IO ()
main = do
    Just credentials <- getCredentialsFromEnv
    cp <- createProvider credentials $ return $ NewDropletArgs
      { name        = "test-droplet"
      , size_slug   = "512mb"
      , -- The image is provisioned with halon from an ubuntu system. It has a
        -- user dev with halon built in its home folder. The image also has
        -- /etc/ssh/ssh_config tweaked so copying files from remote to remote
        -- machine does not store hosts in known_hosts.
        image_id    = "7055005"
      , region_slug = "ams2"
      , ssh_key_ids = ""
      }

    Right nt <- createTransport "localhost" "4000" defaultTCPParameters
    let remoteTable = __remoteTable initRemoteTable
    n0 <- newLocalNode nt remoteTable

    runProcess n0 $ withHostNames cp 2 $ \ms@[m0, m1] -> do

      -- test copying a folder
      copyFiles m0 ms [ ("halond", "halonctl") ]

      systemThere ms ("echo can run a remote command")

      -- test spawning a node
      nid1 <- spawnNode m1 ("halond -l 0.0.0.0:9000")
      nid2 <- spawnNode m2 ("halond -l 0.0.0.0:9000")

      getSelfPid >>= \a -> mapM_ ((flip redirectLogs) a) [nid1,nid2]

      systemThere ms ("halonctl -a 127.0.0.1:9000 boostrap satellite")
      expectLog [nid1] (== "This is HA.NodeAgent")
      expectLog [nid2] (== "This is HA.NodeAgent")
      systemThere m0 ("halonctl -a 127.0.0.1:9000 boostrap station -t 127.0.0.1:9000 -s " ++ m1 ++ ":9000")
      expectLog [nid1] (== "This is HA.TrackingStation")
      systemThere m0 ("halonctl -a " ++ m1 ++ ":9000 service dummy -e 127.0.0.1:9000 start")
      expectLog [nid1] (== "Starting service dummy")

