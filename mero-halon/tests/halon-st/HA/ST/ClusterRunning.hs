{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- A /dummy/ test: pass if the cluster is running: that is every node,
-- process and services is in online state. Serves as a template/guide
-- to how to write these tests.
module HA.ST.ClusterRunning (test) where

import           Control.Distributed.Process
import           Data.Binary (Binary)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import           HA.Resources.Mero as M0
import           HA.Resources.Mero.Note as M0
import           HA.ST.Common
import           Network.CEP
import           Test.Tasty.HUnit (assertEqual, assertFailure)

newtype ST_IsClusterRunning = ST_IsClusterRunning ProcessId
  deriving (Show, Eq, Generic, Typeable)

data ST_IsClusterRunning_Reply = ST_IsClusterRunning_Reply
  [M0.Disposition]
  [(M0.Process, M0.ProcessState)]
  [(M0.Service, M0.ServiceState)]
  deriving (Show, Eq, Generic, Typeable)

instance Binary ST_IsClusterRunning
instance Binary ST_IsClusterRunning_Reply

-- | Gather data about cluster state from RG and send back to the
-- test.
isClusterRunningRule :: Definitions LoopState ()
isClusterRunningRule = defineSimpleTask "st-cluster-running" $ \(ST_IsClusterRunning caller) -> do
  rg <- getLocalGraph
  let disp = G.connectedTo R.Cluster R.Has rg
  let procs = [ (p, M0.getState p rg)
              | prof :: M0.Profile <- G.connectedTo R.Cluster R.Has rg
              , fs :: M0.Filesystem <- G.connectedTo prof M0.IsParentOf rg
              , n :: M0.Node <- G.connectedTo fs M0.IsParentOf rg
              , p :: M0.Process <- G.connectedTo n M0.IsParentOf rg
              ]
  let svs = [ (s, M0.getState s rg)
            | (p, _) <- procs
            , s :: M0.Service <- G.connectedTo p M0.IsParentOf rg ]
  let result = ST_IsClusterRunning_Reply disp procs svs
  liftProcess $ usend caller result

-- | Gather information about cluster disposition, process and service
-- states then expect everything to be online.
test :: HASTTest
test = HASTTest "cluster-running" [isClusterRunningRule] $ \(TestArgs eqs _ _) -> do
  self <- getSelfPid
  let timeout_secs = 10
  _ <- promulgateEQ eqs $ ST_IsClusterRunning self
  expectTimeout (timeout_secs * 1000000) >>= \case
    Nothing -> liftIO . assertFailure $
      "No reply in " ++ show timeout_secs ++ " seconds."
    Just (ST_IsClusterRunning_Reply d ps ss) -> liftIO $ do
      assertEqual "Cluster disposition is online" d [M0.ONLINE]
      let exPs = map (\(p, _) -> (p, M0.PSOnline)) ps
      assertEqual "All processes are online" ps exPs
      let exSs = map (\(s, _) -> (s, M0.SSOnline)) ss
      assertEqual "All services are online" ss exSs
