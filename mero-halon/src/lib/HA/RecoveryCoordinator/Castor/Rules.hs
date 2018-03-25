{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
-- |
-- Copyright : (C) 2015-)017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to Castor install of Mero.

module HA.RecoveryCoordinator.Castor.Rules
 ( castorRules
 , goRack
 ) where

import           Control.Monad.Catch
import           Data.Foldable (for_)
import qualified Data.Text as T

import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.RecoveryCoordinator.Castor.Commands as Commands
import qualified HA.RecoveryCoordinator.Castor.Drive as Drive
import qualified HA.RecoveryCoordinator.Castor.Expander.Rules as Expander
import qualified HA.RecoveryCoordinator.Castor.Filesystem as Filesystem
import qualified HA.RecoveryCoordinator.Castor.Node.Rules as Node
import qualified HA.RecoveryCoordinator.Castor.Process.Rules as Process
import qualified HA.RecoveryCoordinator.Castor.Service as Service
import           HA.RecoveryCoordinator.Mero.Actions.Failure
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Events.Cluster
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import           Network.CEP

-- | Collection of Castor rules.
castorRules :: Definitions RC ()
castorRules = sequence_
  [ ruleInitialDataLoad
  , Filesystem.rules
  , Process.rules
  , Drive.rules
  , Expander.rules
  , Node.rules
  , Service.rules
  , Commands.rules
  ]

-- | Load initial data from facts file into the system.
--
--   TODO We could only use 'syncGraphBlocking' in the preloaded case.
ruleInitialDataLoad :: Definitions RC ()
ruleInitialDataLoad =
  defineSimpleTask "castor::initial-data-load" $ \CI.InitialData{..} -> do
    rg <- getGraph
    let err logPrefix msg = do
          Log.rcLog' Log.ERROR $ logPrefix ++ msg
          notify $ InitialDataLoadFailed msg

        validateConf = validateTransactionCache >>= \case
          Left e -> do
            putGraph rg
            err "Exception during conf validation: " $ show e
          Right (Just e) -> do
            putGraph rg
            err "Conf failed to validate: " e
          Right Nothing -> do
            Log.rcLog' Log.DEBUG "Initial data loaded."
            notify InitialDataLoaded

        load = do
          mapM_ goRack id_racks
          fs <- initialiseConfInRG
          loadMeroGlobals id_m0_globals
          loadMeroServers id_m0_servers
          graph <- getGraph
          Just updateType <- getCurrentGraphUpdateType
          case updateType of
            Iterative update -> do
              Log.rcLog' Log.WARN "iterative graph population - can't test sanity prior to update."
              for_ (update graph) $ \updateGraph -> do
                graph' <- updateGraph $ \rg' -> do
                  putGraph rg'
                  syncGraphBlocking
                  getGraph
                putGraph graph'
                syncGraphBlocking
            Monolithic update -> modifyGraphM update
          -- Note that we call these after doing the 'update', which creates
          -- pool versions for the IO pools. The reason for this is that
          -- 'createIMeta', at least, generates additional disks for use in the
          -- imeta pool. Currently there is no marker on disks to distinguish
          -- which pool they should be in, however, so if these are created
          -- before the update then they get added to the IO pool. The correct
          -- solution will involve proper support for multiple pools and
          -- multiple types of pools. In the meantime, creating these fake
          -- devices later works.
          createMDPoolPVer fs
          createIMeta fs
          validateConf

    if null (G.connectedTo Cluster Has rg :: [Rack])
    then load `catch` ( err "Failure during initial data load: "
                      . (show :: SomeException -> String) )
    else err "" "Initial data is already loaded."

goRack :: CI.Rack -> PhaseM RC l ()
goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
  registerRack rack
  mapM_ (goEnc rack) rack_enclosures

goEnc :: Rack -> CI.Enclosure -> PhaseM RC l ()
goEnc rack (CI.Enclosure{..}) = let
    enclosure = Enclosure enc_id
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc
    mapM_ (goHost enclosure) enc_hosts

goHost :: Enclosure -> CI.Host -> PhaseM RC l ()
goHost enc (CI.Host{..}) = let
    host = Host $ T.unpack h_fqdn
    -- Nodes mentioned in ID are not clients in the 'dynamic' sense.
    remAttrs = [HA_M0CLIENT]
  in do
    registerHost host
    locateHostInEnclosure host enc
    mapM_ (unsetHostAttr host) remAttrs
