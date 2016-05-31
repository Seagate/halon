{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
module HA.RecoveryCoordinator.Rules.Castor.Node
  ( nodeRules
  ) where

import           HA.Encode

import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf

import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G

import Network.CEP
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Typeable
import Control.Applicative ((<|>))
import Control.Monad (unless)

nodeRules :: Definitions LoopState ()
nodeRules = sequence_
  [ ruleNewCastorNode
  , ruleCastorNodeKernelFailure
  ]

ruleNewCastorNode :: Definitions LoopState ()
ruleNewCastorNode = defineSimpleTask "castor::node::new" $ \(NewMeroServer node@(R.Node nid)) -> do
  phaseLog "info" $ "NewMeroServer received for node " ++ show nid
  rg <- getLocalGraph
  case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
    Just M0.MeroClusterStopped -> phaseLog "info" "Cluster is stopped."
    Just M0.MeroClusterStopping{} -> phaseLog "info" "Cluster is stopping."
    Just M0.MeroClusterFailed -> phaseLog "info" "Cluster is in failed state, doing nothing."
    _ -> findNodeHost node >>= \case
      Just host -> do
        phaseLog "info" "Starting core bootstrap"
        let mlnid =
                (listToMaybe [ ip | M0.LNid ip <- G.connectedTo host R.Has rg ])
              <|> (listToMaybe $ [ ip | CI.Interface { CI.if_network = CI.Data, CI.if_ipAddrs = ip:_ }
                                      <- G.connectedTo host R.Has rg ])
        case mlnid of
          Nothing -> do
            phaseLog "warn" $ "Unable to find Data IP addr for host "
                                 ++ show host
          Just lnid -> do
            createMeroKernelConfig host $ lnid ++ "@tcp"
            startMeroService host node
      Nothing -> phaseLog "error" $ "Can't find R.Host for node " ++ show node

ruleCastorNodeKernelFailure :: Definitions LoopState ()
ruleCastorNodeKernelFailure = defineSimpleTask "castor::node:kernel-failure" $ \(M0.MeroKernelFailed msg) -> do
    phaseLog "warn" $ "mero-kernel failed to start: " ++ show msg
    modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
