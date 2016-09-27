{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- A /dummy/ test: pass if the cluster is running: that is every node,
-- process and services is in online state. Serves as a template/guide
-- to how to write these tests.
module HA.ST.ClusterRunning (test) where

import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import           HA.Resources.Mero as M0
import           HA.Resources.Mero.Note as M0
import           HA.ST.Common
import           Test.Tasty.HUnit (assertBool)

test :: HASTTest
test = HASTTest "cluster-running" $ \(TestArgs eqs eqp rcp) -> do
  rg <- G.getGraph mm

  let disp = G.connectedTo R.Cluster R.Has rg
  assertBool "Cluster disposition is online" (disp == [M0.ONLINE])

  let procs = [ p | prof :: M0.Profile <- G.connectedTo R.Cluster R.Has rg
                  , fs :: M0.Filesystem <- G.connectedTo prof M0.IsParentOf rg
                  , n :: M0.Node <- G.connectedTo fs M0.IsParentOf rg
                  , p :: M0.Process <- G.connectedTo n M0.IsParentOf rg
                  ]
  assertBool "All processes are online"
             (all (\p -> M0.getState p rg == M0.PSOnline) procs)

  let svs = [ s | p <- procs
                , s :: M0.Service <- G.connectedTo p M0.IsParentOf rg ]
  assertBool "All services are online"
             (all (\s -> M0.getState s rg == M0.SSOnline) svs)
