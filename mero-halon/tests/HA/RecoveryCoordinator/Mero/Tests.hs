{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2013-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This module contains tests which exercise the RC with respect to
-- mero or its components.
module HA.RecoveryCoordinator.Mero.Tests (tests) where

import           Control.Distributed.Process
import           Control.Monad (unless, void, when)
import           Data.Binary (Binary)
import           Data.Function (on)
import           Data.List
  (isInfixOf, isPrefixOf, partition, sortBy, sort, tails)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.NodeUp (nodeUp)
import           HA.RecoveryCoordinator.Castor.Drive.Events (DriveOK)
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.Events (stateSet)
import           HA.RecoveryCoordinator.Mero.Notifications (setPhaseNotified)
import           HA.RecoveryCoordinator.Mero.State (applyStateChanges)
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Events.Cluster
import           HA.Replicator hiding (getState)
import qualified HA.ResourceGraph as G
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Service (getInterface)
import           HA.Service.Interface
import           HA.Services.SSPL (sspl)
import           HA.Services.SSPL.LL.CEP
import           HA.Services.SSPL.LL.Resources (SsplLlFromSvc(..), LoggerCmd(..))
import           Helper.InitialData
import qualified Helper.Runner as H
import           Helper.SSPL
import           Mero.Lnet
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.CEP
import           Network.Transport (Transport(..))
import           Prelude hiding ((<*>))
import           Test.Framework
import           Test.Tasty.HUnit (assertEqual, assertBool, testCase)
import           TestRunner

tests ::  (Typeable g, RGroup g) => Transport -> Proxy g -> [TestTree]
tests transport pg =
  [ testCase "testDriveManagerUpdate" $ testDriveManagerUpdate transport pg
  , testCase "testConfObjectStateQuery" $ testConfObjectStateQuery transport pg
  , testMero "good-conf-loads" $ testGoodConfLoads transport pg
  , testMero "bad-conf-does-not-load" $ testBadConfDoesNotLoad transport pg
  , testMero "testProcessMultiplicity" $ testProcessMultiplicity transport pg
  ]

-- | Used by 'testDriveManagerUpdate'
newtype RunDriveManagerFailure = RunDriveManagerFailure StorageDevice
  deriving (Eq, Show, Typeable, Generic, Binary)

-- | Update receiving a drive failure from SSPL,
testDriveManagerUpdate :: (Typeable g, RGroup g)
                       => Transport -> Proxy g -> IO ()
testDriveManagerUpdate transport pg = do
  iData <- defaultInitialData
  tos <- H.mkDefaultTestOptions
  let tos' = tos { H._to_cluster_setup = H.NoSetup
                 , H._to_initial_data = iData }
  H.run' transport pg [testRule] tos' $ \ts -> do
    self <- getSelfPid
    let interestingSN = head [ CI.m0d_serial dev
                             | host <- CI.id_m0_servers iData
                             , dev <- CI.m0h_devices host
                             ]
        enc = head [ CI.enc_id encl
                   | site <- CI.id_sites iData
                   , rack <- CI.site_racks site
                   , encl <- CI.rack_enclosures rack
                   ]
        respDM = mkResponseDriveManager (T.pack enc) (T.pack interestingSN) 1

    registerInterceptor $ \case
      str | "lcType = \"HDS\"" `isInfixOf` str ->
              when (any (interestingSN `isPrefixOf`) (tails str)) $
                usend self ("OK" :: String)
          | otherwise -> return ()
    subscribe (H._ts_rc ts) (Proxy :: Proxy DriveOK)
    subscribe (H._ts_rc ts) (Proxy :: Proxy LoggerCmd)

    sayTest "Sending online message"
    sendRC (getInterface sspl) $ DiskStatusDm (processNodeId $ H._ts_rc ts)
                                              (respDM "OK" "NONE" "/path")
    _ :: DriveOK <- expectPublished
    -- XXX: remove this delay it's needed because graph is not updated immediately
    _ <- receiveTimeout 1000000 []

    sayTest "Checking drive status sanity"
    graph <- G.getGraph $ H._ts_mm ts
    let drive = StorageDevice interestingSN
    liftIO . assertBool "drive is resource graph member" $ G.memberResource drive graph
    liftIO . assertBool "status is graph member" $ G.memberResource (StorageDeviceStatus "OK" "NONE") graph

    sayTest "Sending RunDriveManagerFailure"
    usend (H._ts_rc ts) $ RunDriveManagerFailure drive
    expectPublished >>= \case
      LoggerCmd { lcMsg = msg, lcType = "HDS" }
        | T.pack interestingSN `T.isInfixOf` msg -> return ()
      lc -> fail $ "Unexpected LoggerCmd: " ++ show lc
  where
    testRule :: Definitions RC ()
    testRule = defineSimple "dmwf-trigger" $ \(RunDriveManagerFailure sd) -> do
      updateDriveManagerWithFailure sd "FAILED" (Just "injected failure")

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
testConfObjectStateQuery transport pg = do
  iData <- defaultInitialData
  tos <- H.mkDefaultTestOptions
  let tos' = tos { H._to_cluster_setup = H.NoSetup
                 , H._to_initial_data = iData }
  H.run' transport pg [waitFailedSDev] tos' $ \ts -> do
    sayTest "Loading graph."
    graph <- G.getGraph $ H._ts_mm ts
    let sdevs = G.getResourcesOfType graph :: [M0.SDev]
        sdevFids = fmap M0.fid sdevs
        otherFids =
             fmap M0.fid (G.getResourcesOfType graph :: [M0.Root])
          ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Profile])
          ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Site])
          ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Rack])
          ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Enclosure])
          ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Controller])
          ++ fmap M0.fid (G.getResourcesOfType graph :: [M0.Process])
        failFid : okSDevFids = sdevFids
        failSDev : _ = sdevs
        okayFids = okSDevFids ++ otherFids

    self <- getSelfPid
    sayTest "Set to failed one of the objects"
    usend (H._ts_rc ts) $ WaitFailedSDev self failSDev (getState failSDev graph)
    Just rep@WaitFailedSDevReply{} <- expectTimeout 20000000
    sayTest $ "Got reply of " ++ show rep

    sayTest "Send Get message to the RC"
    void $ promulgateEQ [processNodeId $ H._ts_rc ts] (Get self (failFid : okayFids))
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
        _ <- applyStateChanges [ stateSet m0sdev Tr.sdevFailTransient ]
        continue wait_failure

      setPhaseNotified wait_failure (\(_, m0sdev, st) -> Just (m0sdev, (== st))) $ \(d, st) -> do
        (caller, _, _) <- get Local
        liftProcess . usend caller $ WaitFailedSDevReply d st

      start init_state (error "waitFailedSDev: state not initialised")

-- | Helper for conf validation tests.
testConfLoads :: (Typeable g, RGroup g)
              => CI.InitialData -- ^ Initial data to load
              -> Transport -- ^ Transport
              -> Proxy g -- ^ Replicated group type
              -> (InitialDataLoaded -> Bool) -- ^ Expected load result
              -> IO ()
testConfLoads iData transport pg expectedResultP = do
  runDefaultTest transport $ do
    nid <- getSelfNode
    sayTest $ "tests node: " ++ show nid
    withTrackingStation pg [] $ \ta -> do
      nodeUp [nid]
      subscribe (ta_rc ta) (Proxy :: Proxy InitialDataLoaded)
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
      return $ iData { CI.id_m0_servers = invalidateHost <$> CI.id_m0_servers iData }

    -- Set endpoints of processes for the host to invalid value,
    -- making conf fail validation.
    invalidateHost :: CI.M0Host -> CI.M0Host
    invalidateHost h =
      h { CI.m0h_processes =
            (\p -> p { CI.m0p_endpoint = invalidEP $ CI.m0p_endpoint p})
              <$> CI.m0h_processes h
        }

    invalidEP ep = ep {
      process_id = 00000
    }

-- | Test that we can load processes with multiplicity > 1, and that they show
--   up correctly in the resource graph.
testProcessMultiplicity :: (Typeable g, RGroup g)
                        => Transport -> Proxy g -> IO ()
testProcessMultiplicity t pg = runDefaultTest t $ do
    nid <- getSelfNode
    iData <- mkData
    sayTest $ "tests node: " ++ show nid
    withTrackingStation pg [] $ \ta -> do
      nodeUp [nid]
      subscribe (ta_rc ta) (Proxy :: Proxy InitialDataLoaded)
      void $ promulgateEQ [nid] iData
      r <- expectPublished
      unless (r == InitialDataLoaded) $ do
        fail $ "Initial data loaded unexpectedly with " ++ show r
      rg <- G.getGraph $ ta_mm ta
      let procs = Process.getTyped CI.PLM0t1fs rg
      liftIO $ assertEqual "Three m0t1fs processes" 3 (length procs)
  where
    mkData = do
      iData <- liftIO defaultInitialData
      return $ iData { CI.id_m0_servers = mult <$> CI.id_m0_servers iData }
    mult :: CI.M0Host -> CI.M0Host
    mult h = let
        (m0t1fs, others) = partition ((==) CI.PLM0t1fs . CI.m0p_boot_level)
                                     (CI.m0h_processes h)
        m0t1fs' = (\p -> p {CI.m0p_multiplicity = Just 3}) <$> m0t1fs
      in h { CI.m0h_processes = m0t1fs' <> others}
