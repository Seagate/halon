{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2013-2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module contains tests which exercise the RC with respect to
-- mero or its components.
module HA.RecoveryCoordinator.Mero.Tests (tests) where

import           Control.Distributed.Process
import           Control.Monad (unless, void, when)
import           Data.Binary (Binary)
import           Data.Function (on)
import           Data.List (isInfixOf, isPrefixOf, sortBy, sort, tails)
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Castor.Drive.Events (DriveOK)
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.Events (stateSet)
import           HA.RecoveryCoordinator.Mero.Notifications (setPhaseNotified)
import           HA.RecoveryCoordinator.Mero.State (applyStateChanges)
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Events.Cluster
import           HA.Replicator hiding (getState)
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Services.SSPL.CEP
import           Helper.InitialData
import           Helper.SSPL
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.CEP
import           Network.Transport (Transport(..))
import           Prelude hiding ((<$>), (<*>))
import           Test.Framework
import           Test.Tasty.HUnit (assertEqual, testCase)
import           TestRunner

tests ::  (Typeable g, RGroup g) => Transport -> Proxy g -> [TestTree]
tests transport pg =
  [ testCase "testDriveManagerUpdate" $ testDriveManagerUpdate transport pg
  , testCase "testConfObjectStateQuery" $
      testConfObjectStateQuery transport pg
  , testCase "good-conf-loads" $ testGoodConfLoads transport pg
  , testCase "bad-conf-does-not-load" $ testBadConfDoesNotLoad transport pg
  ]

-- | Used by 'testDriveManagerUpdate'
newtype RunDriveManagerFailure = RunDriveManagerFailure StorageDevice
  deriving (Eq, Show, Typeable, Generic, Binary)

-- | Update receiving a drive failure from SSPL,
testDriveManagerUpdate :: (Typeable g, RGroup g)
                       => Transport -> Proxy g -> IO ()
testDriveManagerUpdate transport pg = runDefaultTest transport $ do
  nid <- getSelfNode
  self <- getSelfPid
  iData <- liftIO defaultInitialData
  let interestingSN : _ = [ CI.m0d_serial d | s <- CI.id_m0_servers iData
                                            , d <- CI.m0h_devices s ]
      enc : _ = [ CI.enc_id enc' | r <- CI.id_racks iData
                                 , enc' <- CI.rack_enclosures r ]
      respDM = mkResponseDriveManager (T.pack enc) (T.pack interestingSN) 1

  registerInterceptor $ \case
    str | "lcType = \\\"HDS\\\"}" `isInfixOf` str ->
            when (any (interestingSN `isPrefixOf`) (tails str)) $
              usend self ("OK" :: String)
        | otherwise -> return ()
  withTrackingStation pg [testRule] $ \(TestArgs _ mm rc) -> do
    subscribe rc (Proxy :: Proxy DriveOK)
    subscribe rc (Proxy :: Proxy NewNodeConnected)
    subscribe rc (Proxy :: Proxy InitialDataLoaded)
    nodeUp [nid]

    _ :: NewNodeConnected <- expectPublished

    void $ promulgateEQ [nid] iData
    InitialDataLoaded <- expectPublished

    sayTest "Sending online message"
    promulgateEQ [nid] (nid, respDM "OK" "NONE" "/path") >>= flip withMonitor wait
    _ :: DriveOK <- expectPublished

    sayTest "Checking drive status sanity"
    graph <- G.getGraph mm
    let [drive] = [ d | d <- G.connectedTo (Enclosure enc) Has graph :: [StorageDevice]
                      , DISerialNumber sn <- G.connectedTo d Has graph
                      , sn == interestingSN
                  ]
    assert $ G.memberResource drive graph
    assert $ G.memberResource (StorageDeviceStatus "OK" "NONE") graph

    sayTest "Sending RunDriveManagerFailure"
    usend rc $ RunDriveManagerFailure drive
    liftIO . assertEqual "Drive should be found" ("OK"::String) =<< expect
  where
    testRule :: Definitions RC ()
    testRule = defineSimple "dmwf-trigger" $ \(RunDriveManagerFailure sd) -> do
      updateDriveManagerWithFailure sd "FAILED" (Just "injected failure")

    wait = void (expect :: Process ProcessMonitorNotification)

-- | Used by rule in 'testConfObjectStateQuery'
data WaitFailedSDev = WaitFailedSDev ProcessId M0.SDev M0.SDevState
  deriving (Show, Eq, Generic, Typeable)
instance Binary WaitFailedSDev

data WaitFailedSDevReply = WaitFailedSDevReply M0.SDev M0.SDevState
  deriving (Show, Eq, Generic, Typeable)
instance Binary WaitFailedSDevReply

-- | Test that the recovery coordinator answers queries of configuration object
-- states.
testConfObjectStateQuery :: (Typeable g, RGroup g)
                         => Transport -> Proxy g -> IO ()
testConfObjectStateQuery transport pg =
    runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
      nid <- getSelfNode
      self <- getSelfPid

      sayTest $ "tests node: " ++ show nid
      withTrackingStation pg [waitFailedSDev] $ \(TestArgs _ mm rc) -> do
        subscribe rc (Proxy :: Proxy InitialDataLoaded)
        nodeUp [nid]
        sayTest "Loading graph."
        liftIO defaultInitialData >>= void . promulgateEQ [nid]
        InitialDataLoaded <- expectPublished

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
        sayTest "Set to failed one of the objects"
        usend rc $ WaitFailedSDev self' failSDev (getState failSDev graph)
        Just rep@WaitFailedSDevReply{} <- expectTimeout 20000000
        sayTest $ "Got reply of " ++ show rep

        sayTest "Send Get message to the RC"
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
    waitFailedSDev :: Definitions RC ()
    waitFailedSDev = define "testConfObjectStateQuery::wait-failed-sdev" $ do
      init_state <- phaseHandle "init_state"
      wait_failure <- phaseHandle "wait_failure"

      setPhase init_state $ \(WaitFailedSDev caller m0sdev st) -> do
        let state = M0.sdsFailTransient st
        put Local (caller, m0sdev, state)
        applyStateChanges [ stateSet m0sdev Tr.sdevFailTransient ]
        continue wait_failure

      setPhaseNotified wait_failure (\(_, m0sdev, st) -> Just (m0sdev, (== st))) $ \(d, st) -> do
        (caller, _, _) <- get Local
        liftProcess . usend caller $ WaitFailedSDevReply d st

      start init_state (error "waitFailedSDev: state not initialised")

-- | Helper for conf validation tests.
testConfLoads :: (Typeable g, RGroup g)
                  => CI.InitialData -- ^ Initial data to load
                  -> Transport -> Proxy g
                  -> (InitialDataLoaded -> Bool) -- ^ Expected load result
                  -> IO ()
testConfLoads iData transport pg expectedResultP =
  runTest 1 20 15000000 transport testRemoteTable $ \_ -> do
    nid <- getSelfNode
    sayTest $ "tests node: " ++ show nid
    withTrackingStation pg [] $ \(TestArgs _ _ rc) -> do
      nodeUp [nid]
      subscribe rc (Proxy :: Proxy InitialDataLoaded)
      void $ promulgateEQ [nid] iData
      r <- expectPublished
      unless (expectedResultP r) $ do
        fail $ "Initial data loaded unexpectedly with " ++ show r

-- | Check that we can validate conf for default initial data.
testGoodConfLoads :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testGoodConfLoads t pg = do
  iData <- liftIO defaultInitialData
  testConfLoads iData t pg (== InitialDataLoaded)

-- | Check that we can detect a bad conf. Bad conf is produced by
-- setting invalid endpoints for every process. Only the suffix of the
-- endpoint is preserved, stripping the host prefix.
testBadConfDoesNotLoad :: (Typeable g, RGroup g)
                           => Transport -> Proxy g -> IO ()
testBadConfDoesNotLoad t pg = do
  iData <- mkData
  testConfLoads iData t pg (\case { InitialDataLoadFailed _ -> True ; _ -> False })
  where
    mkData = do
      iData <- liftIO defaultInitialData
      return $ iData { CI.id_m0_servers = map invalidateHost $ CI.id_m0_servers iData }

    -- Set endpoints of processes for the host to invalid value,
    -- making conf fail validation.
    invalidateHost :: CI.M0Host -> CI.M0Host
    invalidateHost h = h { CI.m0h_processes = map (\p -> p { CI.m0p_endpoint = "@tcp:12345:41:901" })
                                              $ CI.m0h_processes h }
