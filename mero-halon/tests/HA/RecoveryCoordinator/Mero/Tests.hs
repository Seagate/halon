{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module contains tests which exercise the RC with respect to
-- mero or its components.
module HA.RecoveryCoordinator.Mero.Tests
  ( testDriveAddition
  , tests
  , emptyRules__static
  ) where

import           Control.Distributed.Process
import           Control.Monad (void)
import           Data.List (isInfixOf)
import           Data.Typeable
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Helpers
import           HA.Replicator hiding (getState)
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           Helper.SSPL
import           Network.Transport (Transport(..))
import           Prelude hiding ((<$>), (<*>))
import           Test.Framework
import           Test.Tasty.HUnit (assertBool, testCase)
import           TestRunner
#ifdef USE_MERO
import           Control.Category ((>>>))
import           Control.Monad (when)
import           Data.Binary (Binary)
import           Data.Function (on)
import           Data.List (isPrefixOf, sortBy, sort)
import           Data.List (tails)
import           Data.SafeCopy
import qualified Data.Text as T
import           GHC.Generics
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Actions.Mero (validateTransactionCache)
import           HA.RecoveryCoordinator.Castor.Drive.Events (DriveOK)
import           HA.RecoveryCoordinator.RC.Events.Cluster
import           HA.RecoveryCoordinator.Mero.Events (stateSet)
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.State (applyStateChanges, setPhaseNotified)
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Services.SSPL.CEP
import           Helper.Environment
import qualified Helper.InitialData
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.CEP
import           Test.Tasty.HUnit (assertEqual)
#endif


tests ::  (Typeable g, RGroup g) => Transport -> Proxy g -> [TestTree]
tests transport pg =
  [ testCase "testDriveAddition" $ testDriveAddition transport pg
#ifdef USE_MERO
  , testCase "testDriveManagerUpdate" $ testDriveManagerUpdate transport pg
  , testCase "testConfObjectStateQuery" $
      testConfObjectStateQuery transport pg
  , testCase "good-conf-validates [disabled by TODO]" $
      when False (testGoodConfValidates transport pg)
  , testCase "bad-conf-does-not-validate [disabled by TODO]" $
      when False (testBadConfDoesNotValidate transport pg)
  , testCase "RG can load different fids with the same type" $ testFidsLoad
#endif
  ]


-- | Test that the recovery co-ordinator successfully adds a drive to the RG,
--   and updates its status accordingly.
testDriveAddition :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDriveAddition transport pg = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid

  registerInterceptor $ \case
      str@"Starting service dummy"   -> usend self str
      str' | "Updating status for device" `isInfixOf` str' ->
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

#ifdef USE_MERO
-- | Used by 'testDriveManagerUpdate'
data RunDriveManagerFailure = RunDriveManagerFailure StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Binary RunDriveManagerFailure

-- | Update receiving a drive failure from SSPL,
testDriveManagerUpdate :: (Typeable g, RGroup g)
                       => Transport -> Proxy g -> IO ()
testDriveManagerUpdate transport pg = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid
  registerInterceptor $ \case
    str | "lcType = \\\"HDS\\\"}" `isInfixOf` str ->
            when (any (interestingSN `isPrefixOf`) (tails str)) $
              usend self ("OK" :: String)
        | otherwise -> return ()
  withTrackingStation pg [testRule] $ \(TestArgs _ mm rc) -> do
    subscribe rc (Proxy :: Proxy DriveOK)
    subscribe rc (Proxy :: Proxy NewNodeConnected)
    subscribe rc (Proxy :: Proxy InitialDataLoaded)
    nodeUp ([nid], 1000000)

    _ <- expectPublished (Proxy :: Proxy NewNodeConnected)

    promulgateEQ [nid] initialData >>= flip withMonitor wait
    _ <- expectPublished (Proxy :: Proxy InitialDataLoaded)

    say "Sending online message"
    promulgateEQ [nid] (nid, respDM "OK" "NONE" "/path") >>= flip withMonitor wait

    _ <- expectPublished (Proxy :: Proxy DriveOK)

    say "Checking drive status sanity"
    graph <- G.getGraph mm
    let [drive] = [ d | d <- G.connectedTo (Enclosure enc) Has graph :: [StorageDevice]
                      , DISerialNumber sn <- G.connectedTo d Has graph
                      , sn == interestingSN
                  ]
    assert $ G.memberResource drive graph
    assert $ G.memberResource (StorageDeviceStatus "OK" "NONE") graph

    say "Sending RunDriveManagerFailure"
    promulgateEQ [nid] (RunDriveManagerFailure drive) >>= flip withMonitor wait
    liftIO . assertEqual "Drive should be found" ("OK"::String) =<< expect
  where
    testRule :: Definitions RC ()
    testRule = defineSimpleTask "dmwf-trigger" $ \(RunDriveManagerFailure sd) -> do
      updateDriveManagerWithFailure sd "FAILED" (Just "injected failure")

    wait = void (expect :: Process ProcessMonitorNotification)
    initialData = Helper.InitialData.initialData systemHostname "192.0.2" 1 12 Helper.InitialData.defaultGlobals
    enc : _ = [ CI.enc_id enc' | r <- CI.id_racks initialData
                               , enc' <- CI.rack_enclosures r ]
    interestingSN : _ = [ CI.m0d_serial d | s <- CI.id_m0_servers initialData
                                          , d <- CI.m0h_devices s ]
    respDM = mkResponseDriveManager (T.pack enc) (T.pack interestingSN) 1

-- | Used by rule in 'testConfObjectStateQuery'
data WaitFailedSDev = WaitFailedSDev ProcessId M0.SDev M0.SDevState
  deriving (Show, Eq, Generic, Typeable)

data WaitFailedSDevReply = WaitFailedSDevReply M0.SDev M0.SDevState
  deriving (Show, Eq, Generic, Typeable)

instance Binary WaitFailedSDev
instance Binary WaitFailedSDevReply

-- | Test that the recovery coordinator answers queries of configuration object
-- states.
testConfObjectStateQuery :: (Typeable g, RGroup g)
                         => Transport -> Proxy g -> IO ()
testConfObjectStateQuery transport pg =
    runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      testSay $ "tests node: " ++ show nid
      withTrackingStation pg [waitFailedSDev] $ \(TestArgs _ mm rc) -> do
        subscribe rc (Proxy :: Proxy InitialDataLoaded)
        nodeUp ([nid], 1000000)
        testSay "Loading graph."
        void $ promulgateEQ [nid] $
          Helper.InitialData.initialData systemHostname "192.0.2.2" 1 12 Helper.InitialData.defaultGlobals
        Just _ <- expectTimeout 20000000 :: Process (Maybe (Published InitialDataLoaded))

        graph <- G.getGraph mm
        let sdevs = G.getResourcesOfType graph :: [M0.SDev]
            sdevFids = fmap M0.fid sdevs
            otherFids =
                 fmap M0.fid (G.getResourcesOfType graph :: [M0.Profile])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Filesystem])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Rack])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Enclosure])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Controller])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Process])
              ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Root])
            failFid : okSDevFids = sdevFids
            failSDev : _ = sdevs
            okayFids = okSDevFids ++ otherFids

        self' <- getSelfPid
        testSay "Set to failed one of the objects"
        void . promulgateEQ [nid] $ WaitFailedSDev self' failSDev (getState failSDev graph)
        Just rep@(WaitFailedSDevReply _ _) <-
          expectTimeout 20000000 :: Process (Maybe WaitFailedSDevReply)
        testSay $ "Got reply of " ++ show rep

        testSay "Send Get message to the RC"
        void $ promulgateEQ [nid] (Get self (failFid : okayFids))
        GetReply notes <- expect
        let resultFids = fmap no_id notes
        liftIO $ assertEqual "Fids should be equal" (sort $ failFid:okayFids) (sort resultFids)
        let expected = map (flip Note M0_NC_ONLINE) (okayFids)
              ++ [Note failFid M0_NC_TRANSIENT]
        liftIO $ assertEqual "result is expected"
                   (sortBy (compare `on` no_id) expected)
                   (sortBy (compare `on` no_id) notes)
  where
    testSay msg = say $ "test => " ++ msg

    waitFailedSDev :: Definitions RC ()
    waitFailedSDev = define "testConfObjectStateQuery::wait-failed-sdev" $ do
      init_state <- phaseHandle "init_state"
      wait_failure <- phaseHandle "wait_failure"

      setPhase init_state $ \(HAEvent uuid (WaitFailedSDev caller m0sdev st)) -> do
        let state = M0.sdsFailTransient st
        put Local (uuid, caller, m0sdev, state)
        applyStateChanges [ stateSet m0sdev Tr.sdevFailTransient ]
        continue wait_failure

      setPhaseNotified wait_failure (\(_, _, m0sdev, st) -> Just (m0sdev, (== st))) $ \(d, st) -> do
        (uuid, caller, _, _) <- get Local
        liftProcess . usend caller $ WaitFailedSDevReply d st
        messageProcessed uuid

      start init_state (error "waitFailedSDev: state not initialised")

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
    validateCacheRules :: [Definitions RC ()]
    validateCacheRules = return $ defineSimple "validate-cache" $ \(HAEvent eid (ValidateCache sender)) -> do
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

deriveSafeCopy 0 'base ''RunDriveManagerFailure
deriveSafeCopy 0 'base ''ValidateCache
deriveSafeCopy 0 'base ''WaitFailedSDev
#endif
