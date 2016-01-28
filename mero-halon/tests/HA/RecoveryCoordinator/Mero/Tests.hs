{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module contains tests which exercise the RC with respect to
-- mero or its components.
module HA.RecoveryCoordinator.Mero.Tests
  ( testDriveAddition
  , testDriveManagerUpdate
  , testHostAddition
#ifdef USE_MERO
  , testRCsyncToConfd
#endif
  , tests
  , emptyRules__static
  ) where

import           Control.Distributed.Process
#ifdef USE_MERO
import           Control.Distributed.Process.Node (runProcess)
#endif
import           Control.Monad (void)
import           Data.Binary
import           Data.List (isInfixOf)
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import           Helper.SSPL
import           Network.CEP (defineSimple, Definitions)
import           Network.Transport (Transport(..))
import           Prelude hiding ((<$>), (<*>))
import qualified SSPL.Bindings as SSPL
import           System.Directory (removeFile)
import           Test.Framework
import           Test.Tasty.HUnit (assertBool, testCase)
import           TestRunner
import           Helper.Environment (systemHostname)
#ifdef USE_MERO
import           Control.Monad (when)
import           Data.Function (on)
import           Data.List (sortBy)
import           HA.Castor.Tests (initialDataAddr)
import           HA.RecoveryCoordinator.Actions.Mero (syncToConfd)
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import qualified Helper.InitialData
import           Mero.Notification
import           Mero.Notification.HAState
#endif

tests :: String -> Transport -> [TestTree]
tests _host transport =
  [ testCase "testHostAddition" $ testHostAddition transport
  , testCase "testDriveAddition" $ testDriveAddition transport
  , testCase "testDriveManagerUpdate" $ testDriveManagerUpdate transport
#ifdef USE_MERO
  , testCase "testConfObjectStateQuery" $
      testConfObjectStateQuery _host transport
#else
  , testCase "testConfObjectStateQuery [disabled by compilation flags]" $
      return ()
#endif
  ]

#ifdef USE_MERO
-- | label used to test spiel sync through a rule
data SpielSync = SpielSync
  deriving (Eq, Show, Typeable, Generic)

instance Binary SpielSync
#endif

#ifdef USE_MERO
-- | Used in 'testRCsyncToConfd'.
testSyncRules :: [Definitions LoopState ()]
testSyncRules = return $ defineSimple "spiel-sync" $ \(HAEvent eid SpielSync _) -> do
  result <- syncToConfd
  case result of
    Left e -> liftProcess $ say $ "Exceptions during sync: "++ show e
    Right{} -> liftProcess $ say "Finished sync to confd"
  messageProcessed eid
#endif

-- | Test that the recovery co-ordinator successfully adds a host to the
--   resource graph.
testHostAddition :: Transport -> IO ()
testHostAddition transport = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      str' | "Registered host" `isInfixOf` str' ->
        usend self ("Host" :: String)
      _ -> return ()

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    say "Send host update message to the RC"
    promulgateEQ [nid] (nid, mockEvent) >>= flip withMonitor wait
    "Host" :: String <- expect

    say "Load graph"
    graph <- G.getGraph mm
    let host = Host "mockhost"
        node = Node nid
    liftIO $ do
      assertBool (show host ++ " is not in graph") $
        G.memberResource host graph
      assertBool (show host ++ " is not connected to " ++ show node) $
        G.memberEdge (G.Edge host Runs node) graph
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    mockEvent = (emptyHostUpdate "mockhost")
      { SSPL.sensorResponseMessageSensor_response_typeHost_updateUname = Just "mockhost"
      }

-- | Test that the recovery co-ordinator successfully adds a drive to the RG,
--   and updates its status accordingly.
testDriveAddition :: Transport -> IO ()
testDriveAddition transport = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      str' | "Updating status for device StorageDevice" `isInfixOf` str' ->
        usend self ("Drive" :: String)
      _ -> return ()

  say $ "tests node: " ++ show nid
  withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    -- Send host update message to the RC
    promulgateEQ [nid] (nid, mockEvent "online" "") >>= flip withMonitor wait
    "Drive" :: String <- expect

    graph <- G.getGraph mm
    let enc = Enclosure "enc1"
        drive = head (G.connectedTo enc Has graph :: [StorageDevice])
        status = StorageDeviceStatus "online"
    liftIO $ do
      assertBool "Enclosure exists in a graph"  $ G.memberResource enc graph
      assertBool "Drive exists in a graph"      $ G.memberResource drive graph
      assertBool "Status exists in a graph"     $ G.memberResource status graph
      assertBool "Enclosure connected to drive" $ G.memberEdge (G.Edge enc Has drive) graph
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    mockEvent = mkResponseDriveManager "enc1" "serial1" 1

-- | Used by 'testDriveManagerUpdate'
data RunDriveManagerFailure = RunDriveManagerFailure
  deriving (Eq, Show, Typeable, Generic)

instance Binary RunDriveManagerFailure

-- | Update receiving a drive failure from SSPL, we're required to
-- update a file for DCS drive manager so that it can reflect on the
-- changes in the file system. This test is unsophisticated in that it
-- only tests that the change to the file is made when event is
-- received and not that the drive manager does something sensible
-- with it.
--
-- * Write out a mock @drive_manager.json@ to have something to update
-- * Insert a drive into RG along with its serial number
-- * Trigger a test rule that calls 'driveManagerUpdateWithFailure'
-- * Check that the failure is now present in the relevant file
--
-- For the sake of testing this, we cheat a bit by triggering it with
-- our own rule. The alternative would be to simulate all kinds of
-- responses from SSPL which aren't central to the feature and are
-- tested separately elsewhere.
testDriveManagerUpdate :: Transport -> IO ()
testDriveManagerUpdate transport = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid
  registerInterceptor $ \case
    str | "drive_manager.json updated successfully" `isInfixOf` str ->
            usend self ("DMUpdated" :: String)
        | "Node succesfully joined the cluster" `isInfixOf` str ->
            usend self  ("NodeUp" :: String)
        | "Loaded initial data" `isInfixOf` str ->
            usend self  ("InitialData" :: String)
        | "at 1 marked as active" `isInfixOf` str ->
            usend self  ("DriveActive" :: String)
        | otherwise -> return ()
  say $ "Writing drive_manager.json with:\n" ++ mockFile
  liftIO $ writeFile "drive_manager.json" mockFile
  withTrackingStation testRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    "NodeUp" :: String <- expect
    promulgateEQ [nid] initialData >>= flip withMonitor wait
    "InitialData" :: String <- expect

    say "Sending online message"
    promulgateEQ [nid] (nid, respDM "online" "") >>= flip withMonitor wait
    "DriveActive" :: String <- expect

    say "Checking drive status sanity"
    graph <- G.getGraph mm
    let [drive] = [ d | d <- G.connectedTo (Enclosure enc) Has graph :: [StorageDevice]
                      , DISerialNumber sn <- G.connectedTo d Has graph
                      , sn == interestingSN
                  ]
    assert $ G.memberResource drive graph
    assert $ G.memberResource (StorageDeviceStatus "online") graph

    say "Sending RunDriveManagerFailure"
    promulgateEQ [nid] RunDriveManagerFailure >>= flip withMonitor wait
    "DMUpdated" :: String <- expect
    content <- liftIO $ readFile "drive_manager.json"
    say $ "drive_manager.json content: \n" ++ content
    assert $ "Failed" `isInfixOf` content
    liftIO $ removeFile "drive_manager.json"
  where
    testRules :: [Definitions LoopState ()]
    testRules = return $ defineSimple "dmwf-trigger" $ \(HAEvent eid RunDriveManagerFailure _) -> do
      -- Find what should be the only SD in the enclosure and trigger
      -- repair on it
      graph <- getLocalGraph
      let [sd] = G.connectedTo (Enclosure enc) Has graph
      updateDriveManagerWithFailure (Just "drive_manager.json") sd
      messageProcessed eid

    wait = void (expect :: Process ProcessMonitorNotification)
    enc :: String
    enc = "enclosure1"
    interestingSN :: String
    interestingSN = "Z8407MGP"
    respDM = mkResponseDriveManager (T.pack enc) (T.pack interestingSN) 1
    initialData = CI.InitialData {
      CI.id_racks = [
        CI.Rack {
          CI.rack_idx = 1
        , CI.rack_enclosures = [
            CI.Enclosure {
              CI.enc_idx = 1
            , CI.enc_id = enc
            , CI.enc_bmc = [CI.BMC "192.0.2.1" "admin" "admin"]
            , CI.enc_hosts = [
                CI.Host {
                  CI.h_fqdn = systemHostname
                , CI.h_memsize = 4096
                , CI.h_cpucount = 8
                , CI.h_interfaces = [
                    CI.Interface {
                      CI.if_macAddress = "10-00-00-00-00"
                    , CI.if_network = CI.Data
                    , CI.if_ipAddrs = ["192.0.2.2"]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
#ifdef USE_MERO
      , CI.id_m0_servers = fmap (\s -> s{CI.m0h_devices = []})
                                (CI.id_m0_servers Helper.InitialData.initialData)
      , CI.id_m0_globals = (CI.id_m0_globals Helper.InitialData.initialData)
                            { CI.m0_failure_set_gen  = CI.Dynamic }
#endif
      }
    mockFile = unlines
      [ "{"
      , "\"drive_manager_version\": 0,"
      , "\"drives\": ["
      , "  {"
      , "    \"reason\": \"None\","
      , "    \"serial_number\": \"" ++ interestingSN ++ "\","
      , "    \"status\": \"OK\""
      , "  },"
      , "  {"
      , "    \"reason\": \"None\","
      , "    \"serial_number\": \"SOMEUNKNOWNDRIVE\","
      , "    \"status\": \"OK\""
      , "  }"
      , "],"
      , "\"format_version\": 0,"
      , "\"last_update_time\": \"1448638074.41\""
      , "}"
      ]

#ifdef USE_MERO
-- | Sends a message to the RC with Confd addition message and tests
-- that it gets added to the resource graph.
testRCsyncToConfd :: String -- ^ IP we're listening on, used in this
                            -- test to assume confd server is on the
                            -- same host
                  -> Transport -> IO ()
testRCsyncToConfd host transport = do
 withTestEnv $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
    str' | "Finished sync to confd" `isInfixOf` str' -> usend self ("SyncOK" :: String)
         | "Loaded initial data" `isInfixOf` str' -> usend self ("InitialLoad" :: String)
         | otherwise -> return ()

  withTrackingStation testSyncRules $ \_ -> do

    promulgateEQ [nid] (initialDataAddr host host 12) >>= flip withMonitor wait
    "InitialLoad" :: String <- expect

    promulgateEQ [nid] SpielSync >>= flip withMonitor wait
    "SyncOK" :: String <- expect
    return ()
  where
    wait = void (expect :: Process ProcessMonitorNotification)
    withTestEnv f = withTmpDirectory $ tryWithTimeoutIO transport testRemoteTable (3*60*1000000)
                  $ \lnid -> do
      initialize_pre_m0_init lnid
      runProcess lnid f

-- | Test that the recovery coordinator answers queries of configuration object
-- states.
testConfObjectStateQuery :: String -> Transport -> IO ()
testConfObjectStateQuery host transport =
    runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      registerInterceptor $ \string -> do
        when ("Loaded initial data" `isInfixOf` string) $
          usend self ("Loaded initial data" :: String)
        when ("mero-note-set synchronized" `isInfixOf` string) $
          usend self ("mero-note-set synchronized" :: String)

      say $ "tests node: " ++ show nid
      withTrackingStation emptyRules $ \(TestArgs _ mm _) -> do
        nodeUp ([nid], 1000000)
        say "Loading graph."
        void $ promulgateEQ [nid] $
          Helper.InitialData.initialDataAddr host "192.0.2.2" 12
        "Loaded initial data" :: String <- expect
        graph <- G.getGraph mm
        let sdevFids = fmap M0.fid (G.getResourcesOfType graph :: [M0.SDev])
            otherFids =
                 fmap M0.fid (G.getResourcesOfType graph :: [M0.Profile])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Filesystem])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Rack])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Enclosure])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Controller])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Disk])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Process])
            failFid : okSDevFids = sdevFids
            okayFids = okSDevFids ++ otherFids

        say "Set to failed one of the objects"
        void $ promulgateEQ [nid] (Set [Note failFid M0_NC_FAILED])
        "mero-note-set synchronized" :: String <- expect

        say "Send Get message to the RC"
        void $ promulgateEQ [nid] (Get self (failFid : okayFids))
        GetReply notes <- expect
        let expected = map (flip Note M0_NC_ONLINE) (okayFids)
              ++ [Note failFid M0_NC_TRANSIENT]
        liftIO $ assertBool
          ("The result (" ++ show notes ++ ") is not the expected one ("
            ++ show expected ++ ")."
          ) $ sortBy (compare `on` no_id) expected
              == sortBy (compare `on` no_id) notes
#endif
