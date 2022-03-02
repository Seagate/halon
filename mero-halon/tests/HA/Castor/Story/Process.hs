{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
-- |
-- Module    : HA.Castor.Story.Process
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Module testing process rules.
--
-- TODO: Put this module elsewhere?
module HA.Castor.Story.Process (mkTests) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Exception as E hiding (assert)
import           Control.Lens
import           Data.Maybe (listToMaybe)
import           Data.Typeable
import           Data.Vinyl
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Node.Events
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events (JobFinished(..))
import           HA.RecoveryCoordinator.Mero
import           HA.Replicator hiding (getState)
import qualified HA.ResourceGraph as G
import           HA.Resources
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import qualified HA.Resources.Castor.Initial as CI
import           Helper.InitialData
import qualified Helper.Runner as H
import           Mero.Notification
import           Network.AMQP
import           Network.CEP
import           Network.Transport
import           Test.Framework

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e::AMQPException) -> return $ \_-> [ testSuccess "Process tests" $ error $ "Rabbitmq failure: " ++ show e]
    Right x -> do
      closeConnection x
      return $ \t ->
        [ testSuccess "Process stop then start" $ testStopStart t pg
        , testSuccess "Cluster bootstraps (4 nodes)" $ testClusterBootstrap t pg
        , testSuccess "m0t1fs start request completes on any cluster level"
          $ testClientStartsAnyBootlevel t pg ]

-- | Stop then start a running process.
testStopStart :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testStopStart transport pg = do
  tos' <- H.mkDefaultTestOptions <&> \tos ->
    tos { H._to_cluster_setup = H.Bootstrapped
        , H._to_run_sspl = False }
  H.run' transport pg [rule] tos' $ \ts -> do
    self <- getSelfPid
    usend (H._ts_rc ts) $ H.RuleHook self
    expect >>= \case
      Nothing -> return ()
      Just err -> fail err
  where
    notifyFailure caller str = liftProcess . usend caller $ Just (str :: String)

    rule :: Definitions RC ()
    rule = define "test-process-stop-start" $ do
      rule_init <- phaseHandle "rule_init"
      process_stopped <- phaseHandle "process_stopped"
      process_started <- phaseHandle "process_started"

      setPhase rule_init $ \(H.RuleHook caller) -> do
        rg <- getGraph
        let ps = listToMaybe $
                 Process.getTyped (CI.PLM0d 1) rg
                  & filter (\p -> getState p rg == M0.PSOnline)
        case ps of
          Nothing ->
            notifyFailure caller "Could not find an online process on boot level 1."
          Just p -> do
            l <- startJob $ StopProcessRequest p
            modify Local $ rlens fldCaller . rfield .~ Just caller
            modify Local $ rlens fldListener . rfield .~ Just l
            continue process_stopped

      setPhaseIf process_stopped ourJob $ \case
        StopProcessResult (p, _) -> do
          l <- startJob $ ProcessStartRequest p
          modify Local $ rlens fldListener . rfield .~ Just l
          continue process_started
        StopProcessTimeout p -> do
          Just caller <- getField . rget fldCaller <$> get Local
          notifyFailure caller $ "Process stop timed out for " ++ showFid p

      setPhaseIf process_started ourJob $ \m -> do
        Just caller <- getField . rget fldCaller <$> get Local
        case m of
          ProcessStarted{} -> liftProcess $ usend caller (Nothing :: Maybe String)
          ProcessConfiguredOnly{} -> liftProcess $ usend caller (Nothing :: Maybe String)
          ProcessStartFailed p m' -> notifyFailure caller $
            "Process start failed for " ++ showFid p ++ " with: " ++ m'
          ProcessStartInvalid p m' -> notifyFailure caller $
            "Process start invalid for " ++ showFid p ++ " with: " ++ m'

      start rule_init args
      where
        fldListener = Proxy :: Proxy '("listener", Maybe ListenerId)
        fldCaller = Proxy :: Proxy '("caller", Maybe ProcessId)

        args = fldListener =: Nothing
           <+> fldCaller   =: Nothing

        ourJob (JobFinished ls m) _ l = case getField $ rget fldListener l of
          Nothing -> error "test-process-stop-start: in ourJob without listener set"
          Just lis -> return $ if lis `elem` ls then Just m else Nothing

testClientStartsAnyBootlevel :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testClientStartsAnyBootlevel transport pg = do
  isettings <- defaultInitialDataSettings
  tos <- H.mkDefaultTestOptions
  idata <- initialData $ isettings { _id_servers = 1 }
  let tos' = tos { H._to_initial_data = idata
                 , H._to_cluster_setup = H.HalonM0DOnly
                 , H._to_run_sspl = False }
  H.run' transport pg [rule] tos' test
  where
    test :: H.TestSetup -> Process ()
    test ts = do
      self <- getSelfPid
      usend (H._ts_rc ts) $ H.RuleHook self
      expect >>= maybe (return ()) fail

    sendToCaller caller m = liftProcess $ usend caller (m :: Maybe String)

    rule = define "test-m0t1fs-starts-any-level" $ do
      rule_init <- phaseHandle "rule_init"
      m0t1fs_result <- phaseHandle "m0t1fs_result"

      setPhase rule_init $ \(H.RuleHook caller) -> do
        -- For a process to start, cluster disposition has to be
        -- online. As we only started halon:m0d, set in manually.
        modifyGraph $ G.connect Cluster Has M0.ONLINE
        -- Check that we're on level 0 (only halon:m0d start after
        -- all), find m0t1fs process, request m0t1fs start through
        -- StartMerClientRequest just like halonctl would
        rg <- getGraph
        case getClusterStatus rg of
          Just (M0.MeroClusterState M0.ONLINE (M0.BootLevel 0) _) -> do
            case Process.getTyped CI.PLM0t1fs rg of
              p : _ -> do
                modify Local $ rlens fldCaller . rfield .~ Just caller
                modify Local $ rlens fldOurProc . rfield .~ Just p
                promulgateRC $ StartMeroClientRequest (M0.fid p)
                continue m0t1fs_result
              [] -> sendToCaller caller $ Just "No m0t1fs processes found"
          cs -> sendToCaller caller . Just $ "Unexpected cluster status: " ++ show cs

      setPhaseIf m0t1fs_result our_m0t1fs $ \r -> do
        rg <- getGraph
        Just caller <- getField . rget fldCaller <$> get Local
        -- Check that cluster is still on the same boot level and we
        -- got process started for the m0t1fs process.
        case getClusterStatus rg of
          Just (M0.MeroClusterState M0.ONLINE (M0.BootLevel 0) _) -> case r of
            ProcessStarted{} -> sendToCaller caller Nothing
            _ -> sendToCaller caller . Just $ show r
          cs -> sendToCaller caller . Just $ "Unexpected cluster status: " ++ show cs

      start rule_init args

      where
        our_m0t1fs msg _ ls = return $ case getField $ rget fldOurProc ls of
          Just p -> case msg of
            ProcessStarted p' | p == p' -> Just msg
            ProcessStartFailed p' _ | p == p' -> Just msg
            ProcessStartInvalid p' _ | p == p' -> Just msg
            _ -> Nothing
          Nothing -> Nothing

        fldCaller = Proxy :: Proxy '("caller", Maybe ProcessId)
        fldOurProc = Proxy :: Proxy '("proc", Maybe M0.Process)
        args = fldCaller =: Nothing
           <+> fldOurProc =: Nothing


-- | Run a bootstrap across 4 nodes
testClusterBootstrap :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testClusterBootstrap transport pg = do
  isettings <- defaultInitialDataSettings
  tos <- H.mkDefaultTestOptions
  idata <- initialData $ isettings { _id_servers = 4 }
  let tos' = tos { H._to_initial_data = idata
                 , H._to_cluster_setup = H.Bootstrapped
                 , H._to_ts_nodes = 2 }
  H.run' transport pg [] tos' (\_ -> return ())
