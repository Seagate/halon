{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE StandaloneDeriving #-}
-- |
-- Module    : HA.Castor.Story.Process
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module testing process rules.
--
-- TODO: Put this module elsewhere?
module HA.Castor.Story.Process (mkTests) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Exception as E hiding (assert)
import           Control.Lens
import           Data.Binary (Binary)
import           Data.Maybe (listToMaybe)
import           Data.Typeable
import           Data.Vinyl
import           GHC.Generics (Generic)
import qualified HA.Castor.Story.Tests as H
import           HA.RecoveryCoordinator.Actions.Mero (getLabeledProcesses)
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events (JobFinished(..))
import           HA.RecoveryCoordinator.Mero
import           HA.Replicator hiding (getState)
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           Helper.InitialData
import           Mero.Notification
import           Network.AMQP
import           Network.CEP
import           Network.Transport
import           Test.Framework

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (_::AMQPException) -> return $ \_-> []
    Right x -> do
      closeConnection x
      return $ \t ->
        [ testSuccess "Process stop then start" $ testStopStart t pg
        , testSuccess "Cluster bootstraps (4 nodes)" $ testClusterBootstrap t pg ]

-- | Used to fire internal test rules
newtype RuleHook = RuleHook ProcessId
  deriving (Generic, Typeable, Binary)

-- | Stop then start a running process.
testStopStart :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testStopStart transport pg = do
  tos' <- H.mkDefaultTestOptions <&> \tos ->
    tos { H._to_cluster_setup = H.Bootstrapped }
  H.run' transport pg [rule] tos' $ \ts -> do
    self <- getSelfPid
    usend (H._ts_rc ts) $ RuleHook self
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

      setPhase rule_init $ \(RuleHook caller) -> do
        rg <- getLocalGraph
        let ps = listToMaybe $
                 getLabeledProcesses (M0.PLBootLevel $ M0.BootLevel 1)
                                     (\p rg' -> getState p rg' == M0.PSOnline) rg
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

-- | Run a bootstrap across 4 nodes
testClusterBootstrap :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testClusterBootstrap transport pg = do
  isettings <- defaultInitialDataSettings
  tos <- H.mkDefaultTestOptions
  idata <- initialData $ isettings { _id_servers = 4 }
  let tos' = tos { H._to_initial_data = idata
                 , H._to_cluster_setup = H.Bootstrapped }
  H.run' transport pg [] tos' (\_ -> return ())
