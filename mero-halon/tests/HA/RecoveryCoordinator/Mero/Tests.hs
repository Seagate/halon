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
  , testHostAddition
#ifdef USE_MERO
  , testRCsyncToConfd
  , testGoodConfValidates
  , testBadConfDoesNotValidate
#endif
  , tests
  , emptyRules__static
  ) where

import           Control.Distributed.Process
#ifdef USE_MERO
import           Control.Distributed.Process.Node (runProcess)
#endif
import           Data.List (isInfixOf, isPrefixOf, tails)
import           Control.Monad (when, void)
import           Data.Binary
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Events.Drive (DriveOK)
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.Replicator
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import           HA.Services.SSPL.CEP
import           Helper.SSPL
import           Network.CEP (defineSimple, Definitions, Published, subscribe)
import           Network.Transport (Transport(..))
import           Prelude hiding ((<$>), (<*>))
import qualified SSPL.Bindings as SSPL
import           Test.Framework
import           Test.Tasty.HUnit (assertBool, assertEqual, testCase)
import           TestRunner
import           Helper.Environment
#ifdef USE_MERO
import           Control.Category ((>>>))
import           Data.Function (on)
import           Data.List (sortBy, sort)
import           HA.RecoveryCoordinator.Actions.Mero (syncToConfd, validateTransactionCache)
import           HA.Services.Mero
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import qualified Helper.InitialData
import           Mero.Notification
import           Mero.Notification.HAState
import qualified Data.UUID as UUID
import           HA.Service
#endif


tests ::  (Typeable g, RGroup g) => String -> Transport -> Proxy g -> [TestTree]
tests host transport pg =
  [ testCase "testHostAddition" $ testHostAddition transport pg
  , testCase "testDriveAddition" $ testDriveAddition transport pg
  , testCase "testDriveManagerUpdate" $ testDriveManagerUpdate host transport pg
#ifdef USE_MERO
  , testCase "testConfObjectStateQuery" $
      testConfObjectStateQuery host transport pg
  , testCase "good-conf-validates [disabled by TODO]" $
      when False (testGoodConfValidates transport pg)
  , testCase "bad-conf-does-not-validate [disabled by TODO]" $
      when False (testBadConfDoesNotValidate transport pg)
  , testCase "RG can load different fids with the same type" $ testFidsLoad
#else
  , testCase "testConfObjectStateQuery [disabled by compilation flags]" $
      return ()
  , testCase "good-conf-validates [disabled by compilation flags]" $ return ()
  , testCase "bad-conf-does-not-validate [disabled by compilation flags]" $
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
testHostAddition :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testHostAddition transport pg = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      str' | "Registered host" `isInfixOf` str' ->
        usend self ("Host" :: String)
      _ -> return ()

  say $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs _ mm _) -> do
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
testDriveAddition :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDriveAddition transport pg = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      str' | "Updating status for device StorageDevice" `isInfixOf` str' ->
        usend self ("Drive" :: String)
      _ -> return ()

  say $ "tests node: " ++ show nid
  withTrackingStation pg emptyRules $ \(TestArgs _ mm _) -> do
    nodeUp ([nid], 1000000)
    -- Send host update message to the RC
    promulgateEQ [nid] (nid, mockEvent "OK" "NONE" "/path") >>= flip withMonitor wait
    "Drive" :: String <- expect

    graph <- G.getGraph mm
    let enc = Enclosure "enc1"
        drive = head (G.connectedTo enc Has graph :: [StorageDevice])
        status = StorageDeviceStatus "OK" "NONE"
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

-- | Update receiving a drive failure from SSPL,
testDriveManagerUpdate :: (Typeable g, RGroup g)
                       => String -> Transport -> Proxy g -> IO ()
testDriveManagerUpdate host transport pg = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid
  registerInterceptor $ \case
    str | "Node succesfully joined the cluster" `isInfixOf` str ->
            usend self  ("NodeUp" :: String)
        | "Loaded initial data" `isInfixOf` str ->
            usend self  ("InitialData" :: String)
        | "lcType = \"HDS\"}" `isInfixOf` str ->
            when (any (interestingSN `isPrefixOf`) (tails str)) $
              usend self ("OK" :: String)
        | otherwise -> return ()
  withTrackingStation pg testRules $ \(TestArgs _ mm rc) -> do

    subscribe rc (Proxy :: Proxy DriveOK)

    nodeUp ([nid], 1000000)
    "NodeUp" :: String <- expect
    promulgateEQ [nid] initialData >>= flip withMonitor wait
    "InitialData" :: String <- expect

    say "Sending online message"
    promulgateEQ [nid] (nid, respDM "OK" "NONE" "/path") >>= flip withMonitor wait

    _ <- expect :: Process (Published DriveOK)

    say "Checking drive status sanity"
    graph <- G.getGraph mm
    let [drive] = [ d | d <- G.connectedTo (Enclosure enc) Has graph :: [StorageDevice]
                      , DISerialNumber sn <- G.connectedTo d Has graph
                      , sn == interestingSN
                  ]
    assert $ G.memberResource drive graph
    assert $ G.memberResource (StorageDeviceStatus "OK" "NONE") graph

    say "Sending RunDriveManagerFailure"
    promulgateEQ [nid] RunDriveManagerFailure >>= flip withMonitor wait
    liftIO . assertEqual "Drive should be found" ("OK"::String) =<< expect
  where
    testRules :: [Definitions LoopState ()]
    testRules = pure $ defineSimple "dmwf-trigger" $ \(HAEvent eid RunDriveManagerFailure _) -> do
      -- Find what should be the only SD in the enclosure and trigger
      -- repair on it
      graph <- getLocalGraph
      let [sd] = G.connectedTo (Enclosure enc) Has graph
      updateDriveManagerWithFailure sd "FAILED" (Just "injected failure")
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
                    , CI.if_ipAddrs = [ host ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
#ifdef USE_MERO
      , CI.id_m0_servers =
          fmap (\s -> s{CI.m0h_devices = []})
               (CI.id_m0_servers $ Helper.InitialData.initialData systemHostname "192.0.2" 1 12 Helper.InitialData.defaultGlobals)
      , CI.id_m0_globals = Helper.InitialData.defaultGlobals
                            { CI.m0_failure_set_gen  = CI.Dynamic }
#endif
      }

#ifdef USE_MERO
-- | Sends a message to the RC with Confd addition message and tests
-- that it gets added to the resource graph.
testRCsyncToConfd :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testRCsyncToConfd transport pg = do
 withTestEnv $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
    str' | "Finished sync to confd" `isInfixOf` str' -> usend self ("SyncOK" :: String)
         | "Loaded initial data" `isInfixOf` str' -> usend self ("InitialLoad" :: String)
         | otherwise -> return ()

  withTrackingStation pg testSyncRules $ \_ -> do
    nodeUp ([nid],1000000)

    promulgateEQ [nid] Helper.InitialData.defaultInitialData
      >>= flip withMonitor wait
    "InitialLoad" :: String <- expect

    let mockMeroConf = MeroConf (testListenName++"@tcp:12345:34:101") "<p|1:1>" (MeroKernelConf UUID.nil)
    _ <- promulgateEQ [nid] $ encodeP $ ServiceStartRequest Start (Node nid) m0d mockMeroConf [self]
    _ <- receiveTimeout 1000000 []

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
testConfObjectStateQuery :: (Typeable g, RGroup g)
                         => String -> Transport -> Proxy g -> IO ()
testConfObjectStateQuery host transport pg =
    runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      registerInterceptor $ \string -> do
        when ("Loaded initial data" `isInfixOf` string) $
          usend self ("Loaded initial data" :: String)
        when ("handleReset synchronized" `isInfixOf` string) $
          usend self ("mero-note-set synchronized" :: String)

      say $ "tests node: " ++ show nid
      withTrackingStation pg emptyRules $ \(TestArgs _ mm _) -> do
        nodeUp ([nid], 1000000)
        say "Loading graph."
        void $ promulgateEQ [nid] $
          Helper.InitialData.initialData host "192.0.2.2" 1 12 Helper.InitialData.defaultGlobals
        "Loaded initial data" :: String <- expect
        graph <- G.getGraph mm
        let sdevFids = fmap M0.fid (G.getResourcesOfType graph :: [M0.SDev])
            otherFids =
                 fmap M0.fid (G.getResourcesOfType graph :: [M0.Profile])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Filesystem])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Rack])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Enclosure])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Controller])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Process])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Root])
            failFid : okSDevFids = sdevFids
            okayFids = okSDevFids ++ otherFids

        say "Set to failed one of the objects"
        void $ promulgateEQ [nid] (Set [Note failFid M0_NC_FAILED])
        "mero-note-set synchronized" :: String <- expect

        say "Send Get message to the RC"
        void $ promulgateEQ [nid] (Get self (failFid : okayFids))
        GetReply notes <- expect
        let resultFids = fmap no_id notes
        liftIO $ assertEqual "Fids should be equal" (sort $ failFid:okayFids) (sort resultFids)
        let expected = map (flip Note M0_NC_ONLINE) (okayFids)
              ++ [Note failFid M0_NC_TRANSIENT]
        liftIO $ assertEqual "result is expected"
                   (sortBy (compare `on` no_id) expected)
                   (sortBy (compare `on` no_id) notes)
#endif

#ifdef USE_MERO
-- | Validation query. Reply sent to the given process id.
newtype ValidateCache = ValidateCache ProcessId
  deriving (Eq, Show, Ord, Generic)

instance Binary ValidateCache

-- | Validation result used for validation tests
newtype ValidateCacheResult = ValidateCacheResult (Maybe String)
  deriving (Eq, Show, Ord, Generic)

instance Binary ValidateCacheResult

-- | Helper for conf validation tests.
--
-- Requires mero running.
testConfValidates :: (Typeable g, RGroup g)
                  => CI.InitialData
                  -> Transport -> Proxy g -> Process () -> IO ()
testConfValidates iData transport pg act =
  runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
    nid <- getSelfNode
    self <- getSelfPid

    registerInterceptor $ \string -> do
      when ("Loaded initial data" `isInfixOf` string) $
        usend self ("Loaded initial data" :: String)

    say $ "tests node: " ++ show nid
    withTrackingStation pg validateCacheRules $ \(TestArgs _ _ _) -> do
      nodeUp ([nid], 1000000)
      say "Loading graph."
      void $ promulgateEQ [nid] iData

      "Loaded initial data" :: String <- expect
      say "Sending validate"
      void . promulgateEQ [nid] $ ValidateCache self
      act
  where
    validateCacheRules :: [Definitions LoopState ()]
    validateCacheRules = return $ defineSimple "validate-cache" $ \(HAEvent eid (ValidateCache sender) _) -> do
      liftProcess $ say "validating cache"
      Right res <- validateTransactionCache
      liftProcess . say $ "validated cache: " ++ show res
      liftProcess . usend sender $ ValidateCacheResult res
      messageProcessed eid

-- | Check that we can validate conf string for sample initial data
testGoodConfValidates :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testGoodConfValidates transport pg = testConfValidates iData transport pg $ do
  ValidateCacheResult Nothing <- expect
  return ()
  where
    iData = Helper.InitialData.defaultInitialData

-- | Check that we can detect a bad conf
--
-- TODO find initial data that will produce invalid conf string.
testBadConfDoesNotValidate :: (Typeable g, RGroup g)
                           => Transport -> Proxy g -> IO ()
testBadConfDoesNotValidate transport pg =
    testConfValidates iData transport pg $ do
      ValidateCacheResult (Just _) <- expect
      return ()
  where
    -- TODO manipulate initial data in a way that produces invalid
    -- context that we can then test against. Unfortunately even in
    -- mero the test for this does not yet exist so we can't steal any
    -- ideas.
    iData = Helper.InitialData.defaultInitialData
#endif

#ifdef USE_MERO
testFidsLoad :: IO ()
testFidsLoad = do
  let mmchan = error "Graph mmchan is not used in this test"
      fids = [ M0.fidInit (Proxy :: Proxy M0.RackV) 1 1
             , M0.fidInit (Proxy :: Proxy M0.DiskV) 2 3
             ]
  let g  = G.newResource (M0.RackV (fids !! 0))
       >>> G.newResource (M0.DiskV (fids !! 1))
         $ G.emptyGraph mmchan
  liftIO $ assertEqual "all objects should be found" 2 (length $ lookupConfObjectStates fids g)
#endif
