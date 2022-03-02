-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Collection of helpers for distributed tests.

module HA.Test.Distributed.Helpers where

import Control.Distributed.Commands.Management (copyFilesMove, HostName)
import Control.Distributed.Process
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe
import Data.Proxy
import HA.RecoveryCoordinator.RC
import HA.RecoveryCoordinator.RC.Events.Cluster
import HA.Resources
import Network.CEP hiding (timeout)
import System.Environment
import System.FilePath ((</>))

-- | Requests 'ProcessId' of the RC. Uses the EQ running on the
-- given 'NodeId'. Subscribes to events that may be interesting to
-- distributed tests.
waitForRCAndSubscribe :: [NodeId] -- ^ EQ nodes
                      -> Process ()
waitForRCAndSubscribe nids = do
  subscribeOnTo nids (Proxy :: Proxy NewNodeConnected)

-- | Wait until 'NewNodeConnected' for given 'NodeId' is published by the RC.
waitForNewNode :: NodeId -> Int -> Process (Maybe NodeId)
waitForNewNode nid t = receiveTimeout t
  [ matchIf (\(Published (NewNodeConnected (Node nid')) _) -> nid == nid')
            (const $ return nid)
  ]

dummyStartedLine :: String
dummyStartedLine = "[Service:dummy] starting at "

dummyAlreadyLine :: String
dummyAlreadyLine = "[Service:dummy] already running"

pingStartedLine :: String
pingStartedLine = "[Service:ping] starting at "

-- | Copy mero system library and its dependencies to the given hosts
copyMeroLibs :: MonadIO m => HostName -> [HostName] -> m ()
copyMeroLibs lh ms = liftIO $ do
  meroPath <- fromMaybe "/mero" <$> lookupEnv "M0_SRC_DIR"
  copyFilesMove lh ms
    [ (meroPath </> "mero/.libs/libmero.so.1", "/usr/lib64/libmero.so.1", "libmero.so.1")
    , ("/lib64/libaio.so.1", "/usr/lib64/libaio.so.1", "libaio.so.1")
    , ("/lib64/libyaml-0.so.2", "/usr/lib64/libyaml-0.so.2", "libyaml-0.so.2")
    , ( meroPath </> "extra-libs/gf-complete/src/.libs/libgf_complete.so.1"
      , "/usr/lib64/libgf_complete.so.1"
      , "libgf_complete.so.1"
      )
    ]
