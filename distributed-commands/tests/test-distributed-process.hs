--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Tests the distributed process interface for distributed tests.
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
  , withDigitalOceanDo
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
main = withDigitalOceanDo $ do
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
    n1 <- newLocalNode nt remoteTable

    runProcess n0 $ withHostNames cp 2 $ \ms@[m0, m1] -> do

      -- test copying a folder
      copyFiles m0 [m1] [ ("halon", "test-halon") ]

      systemThere ms ("echo can run a remote command")

      -- test spawning a node
      nid1 <- spawnNode m1 ("echo '" ++ (show $ encode $ localNodeId n1) ++ "'")
      getSelfPid >>= redirectLogs nid1

      liftIO $ runProcess n1 $ say "a test message"

      expectLog [nid1] (== "a test message")
