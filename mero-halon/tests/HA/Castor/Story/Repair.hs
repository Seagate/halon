{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Testing of SNS repair/rebalance logic and interaction with mero.
module HA.Castor.Story.Repair where

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types (LocalNode)
import           Control.Monad ((>=>))
import           Data.List (isInfixOf)
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.NodeUp
import           HA.RecoveryCoordinator.Actions.Core
import           HA.ResourceGraph
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Helper.Environment (systemHostname)
import qualified Helper.InitialData as CI (defaultGlobals, initialData)
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.CEP
import           Network.Transport (Transport)
import           RemoteTables (remoteTable)
import           System.Directory (withCurrentDirectory)
import           System.Process (createProcess, shell, waitForProcess)
import           Test.Framework ( registerInterceptor, testSuccess
                                , withTmpDirectory)
import           Test.Tasty (TestTree)
import           TestRunner ( runTest, __remoteTableDecl, TestArgs
                            , withTrackingStation)

tests :: Transport -> [TestTree]
tests transport =
  [ testSuccess "testRepair" $
      testRepair transport
  ]

-- | Data used throughout tests.
data TestEnv = TestEnv
  { _teHostIP :: String
  -- ^ IP of the host node to listen on.
  , _teMeroRoot :: FilePath
  -- ^ Path of mero root repository containing compiled sources.
  , _teInitialData :: CI.InitialData
  -- ^ 'CI.InitialData' to use throughout the tests.
  , _teHostname :: String
  -- ^ Hostname of the node
  } deriving (Show, Eq)

-- | Given a list of commands, run them in a 'shell' in order, waiting
-- for each process to terminate before calling the next one
runCommands :: [String] -> IO ()
runCommands =
  mapM_ (createProcess . shell >=> \(_, _, _, h) -> waitForProcess h)

cleanUpEnv :: IO ()
cleanUpEnv = runCommands
  [ "sudo killall halond || true"
  , "sleep 1"
  , "sudo rm -rf halon-persistence"
  , "sudo systemctl stop mero-kernel"
  , "sudo killall -9 lt-m0d m0d lt-m0mkfs m0mkfs || true"
  , "sudo rm -rf /var/mero"
  ]

setupEnv :: TestEnv -> IO ()
setupEnv te = withCurrentDirectory (_teMeroRoot te) $ runCommands
  [ "sudo scripts/install-mero-service -u"
  , "sudo scripts/install-mero-service -l"
  , "sudo utils/m0setup -v -P 6 -N 2 -K 1 -i 1 -d /var/mero/img -s 128 -c"
  , "sudo utils/m0setup -v -P 6 -N 2 -K 1 -i 1 -d /var/mero/img -s 128"
  , "sudo rm -vf /etc/mero/genders"
  , "sudo rm -vf /etc/mero/conf.xc"
  , "sudo rm -vf /etc/mero/disks*.conf"
  ]

getTestEnv :: IO TestEnv
getTestEnv = do
  let subnet = "10.0.2"
      hostIP = subnet ++ ".15"
      initialData = CI.initialData systemHostname subnet 1 6 CI.defaultGlobals
  return $ TestEnv
    { _teHostIP = hostIP
    , _teMeroRoot = "/mnt/home/programming/halon-clean/vendor/mero"
    , _teInitialData = initialData
    , _teHostname = systemHostname
    }

-- | 'RemoteTable' used in this module.
myRT :: RemoteTable
myRT = TestRunner.__remoteTableDecl remoteTable

testWithMero :: Transport
              -> [Definitions LoopState ()]
              -- ^ Rules to use in the test
              -> (LocalNode -> TestEnv -> ProcessId
                  -> NodeId -> TestArgs -> Process ())
              -- ^ Test to run
              -> IO ()
testWithMero t rs test = withTmpDirectory $
  runTest 2 20 15000000 t myRT $ \[n] -> do
    tenv <- liftIO $ do
      tenv <- getTestEnv
      cleanUpEnv
      setupEnv tenv
      return tenv
    self <- getSelfPid
    nid <- getSelfNode
    withTrackingStation rs $ \ta -> do
      test n tenv self nid ta

-- | Fail a random drive, wait until repaired message comes back,
-- ensure repair is completed on halon side and that the drive is in
-- 'M0_NC_REPAIRED' state.
testRepair :: Transport -> IO ()
testRepair t = testWithMero t [testRules] $ \n tenv self nid ta -> do
  registerInterceptor $ \case
    str | "Node succesfully joined the cluster" `isInfixOf` str -> usend self "NodeUp"
        | otherwise -> return ()
  nodeUp ([nid], 1000000)
  say $ "Waiting for NodeUp"
  "NodeUp" <- expect
  say $ "Sending ID: " ++ show (_teInitialData tenv)
  _ <- promulgateEQ [nid] $ _teInitialData tenv
  say $ "Waiting for ID"
  _ <- expect :: Process (Published (HAEvent CI.InitialData))
  say $ "Sending self"
  promulgateEQ [nid] ((), self, ())
  ((), disk, ()) <- expect :: Process ((), M0.Disk, ())
  say $ "testRepair: " ++ show disk
  where
    testRules :: Definitions LoopState ()
    testRules = defineSimple "fail-random-drive" $ \(HAEvent eid ((), pid, ()) _) -> do
      g <- getLocalGraph
      let disk :: M0.Disk
          disk = head $ getResourcesOfType g
      liftProcess . promulgate $ Set [Note (M0.fid disk) M0.M0_NC_FAILED]
      liftProcess . usend pid $ ((), disk, ())
      messageProcessed eid
