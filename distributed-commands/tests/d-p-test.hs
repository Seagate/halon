-- Tests the distributed process interface for distributed tests.

import Control.Distributed.Commands.DigitalOcean (getCredentialsFromEnv)
import Control.Distributed.Test.Process
  ( withMachineIPs
  , copyFilesTo
  , runIn
  , copyFilesTo
  , spawnNode
  , copyLog
  , allMessages
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Test.Providers.DigitalOcean
  ( createCloudProvider
  , withDigitalOceanDo
  , NewDropletArgs(..)
  )

import Control.Distributed.Process (say, liftIO)
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
    cp <- createCloudProvider credentials $ return $ NewDropletArgs
      { name        = "test-droplet"
      , size_slug   = "512mb"
      , image_id    = "7055005"
      , region_slug = "ams2"
      , ssh_key_ids = ""
      }

    Right nt <- createTransport "localhost" "4000" defaultTCPParameters
    let remoteTable = __remoteTable initRemoteTable
    n0 <- newLocalNode nt remoteTable
    n1 <- newLocalNode nt remoteTable

    runProcess n0 $ withMachineIPs cp 2 $ \ms@[m0, m1] -> do

      -- test copying a folder
      copyFilesTo m0 [m1] [ ("halon", "test-halon") ]

      runIn ms ("echo can run a remote command")

      -- test spawning a node
      nid1 <- spawnNode m1 ("echo '" ++ (show $ encode $ localNodeId n1) ++ "'")
      copyLog nid1 allMessages

      liftIO $ runProcess n1 $ say "a test message"

      expectLog [nid1] (== "a test message")
