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
  , goRack_XXX0
  ) where

import           Control.Monad.Catch (catch, SomeException)
import           Data.Foldable (for_)
import qualified Data.Text as T

import qualified HA.RecoveryCoordinator.Actions.Hardware as HW
import qualified HA.RecoveryCoordinator.Actions.Mero as M0
import qualified HA.RecoveryCoordinator.Castor.Commands as Commands
import qualified HA.RecoveryCoordinator.Castor.Drive as Drive
import qualified HA.RecoveryCoordinator.Castor.Expander.Rules as Expander
import qualified HA.RecoveryCoordinator.Castor.Filesystem as Filesystem
import qualified HA.RecoveryCoordinator.Castor.Node.Rules as Node
import qualified HA.RecoveryCoordinator.Castor.Process.Rules as Process
import qualified HA.RecoveryCoordinator.Castor.Service as Service
-- import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as SD
import           HA.RecoveryCoordinator.Mero.Actions.Failure
  ( UpdateType(Iterative,Monolithic)
  , getCurrentGraphUpdateType
  )
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Events.Cluster
  ( InitialDataLoaded(..)
  , InitialDataLoaded_XXX3(..)
  )
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Castor.Initial as CI
import           Network.CEP

-- | Collection of Castor rules.
castorRules :: Definitions RC ()
castorRules = sequence_
  [ ruleInitialDataLoad
  , ruleInitialDataLoad_XXX3
  , Filesystem.rules
  , Process.rules
  , Drive.rules
  , Expander.rules
  , Node.rules
  , Service.rules
  , Commands.rules
  ]

-- | Load 'InitialData', obtained from facts file, into the system.
ruleInitialDataLoad :: Definitions RC ()
ruleInitialDataLoad =
    defineSimpleTask "castor::initial-data-load" $ \idata -> do
        rg <- getLocalGraph
        if null (G.connectedTo Cluster Has rg :: [Cas.Rack])
        then loadInitialData idata `catch`
            ( err "Failure during initial data load: "
            . (show :: SomeException -> String) )
        else err "" "Initial data is already loaded"
  where
    err :: String -> String -> PhaseM RC l ()
    err logPrefix msg = do
        Log.rcLog' Log.ERROR (logPrefix ++ msg)
        notify (InitialDataLoadFailed msg)

loadInitialData :: CI.InitialData -> PhaseM RC l ()
loadInitialData CI.InitialData{..} = do
    for_ _id_racks goRack
    M0.initialiseConfInRG _id_profiles

goRack :: CI.Rack -> PhaseM RC l ()
goRack CI.Rack{..} = do
    let rack = Cas.Rack rack_idx
    HW.registerRack rack
    for_ rack_enclosures $ goEnclosure rack

goEnclosure :: Cas.Rack -> CI.Enclosure -> PhaseM RC l ()
goEnclosure rack CI.Enclosure{..} = do
    let encl = Cas.Enclosure (T.unpack enc_id)
    HW.registerEnclosure rack encl
    for_ enc_bmc $ HW.registerBMC encl
    for_ enc_controllers $ goController encl

goController :: Cas.Enclosure -> CI.Controller -> PhaseM RC l ()
goController encl CI.Controller{..} = do
    HW.registerHost host
    HW.locateHostInEnclosure host encl
    -- Nodes mentioned in ID are not clients in the 'dynamic' sense.
    HW.unsetHostAttr host Cas.HA_M0CLIENT
    for_ c_disks goDisk
  where
    host = Cas.Host (T.unpack c_fqdn) -- XXX TODO: s/Host/Controller/
    goDisk CI.Disk{..} = do
        -- let sdev = Cas.StorageDevice d_serial
        --     devIds = [Cas.DIWWN d_wwn, Cas.DIPath d_path]
        --     slot = Cas.Slot encl_XXX d_slot
        -- SD.identify sdev devIds
        let _ = host -- XXX DELETEME
        error "XXX IMPLEMENTME"

-- XXX --------------------------------------------------------------

-- | Load initial data from facts file into the system.
--
--   TODO We could only use 'syncGraphBlocking' in the preloaded case.
ruleInitialDataLoad_XXX3 :: Definitions RC ()
ruleInitialDataLoad_XXX3 =
  defineSimpleTask "castor::initial-data-load_XXX3" $ \CI.InitialData_XXX0{..} -> do
    rg <- getLocalGraph
    let err logPrefix msg = do
          Log.rcLog' Log.ERROR $ logPrefix ++ msg
          notify $ InitialDataLoadFailed_XXX3 msg

        validateConf = M0.validateTransactionCache >>= \case
          Left e -> do
            putLocalGraph rg
            err "Exception during conf validation: " $ show e
          Right (Just e) -> do
            putLocalGraph rg
            err "Conf failed to validate: " e
          Right Nothing -> do
            Log.rcLog' Log.DEBUG "Initial data loaded."
            notify InitialDataLoaded_XXX3

        load = do
          mapM_ goRack_XXX0 id_racks_XXX0
          filesystem <- M0.initialiseConfInRG_XXX3
          M0.loadMeroGlobals id_m0_globals_XXX0
          M0.loadMeroServers filesystem id_m0_servers_XXX0
          graph <- getLocalGraph
          Just updateType <- getCurrentGraphUpdateType
          case updateType of
            Iterative update -> do
              Log.rcLog' Log.WARN "iterative graph population - can't test sanity prior to update."
              for_ (update graph) $ \updateGraph -> do
                graph' <- updateGraph $ \rg' -> do
                  putLocalGraph rg'
                  syncGraphBlocking
                  getLocalGraph
                putLocalGraph graph'
                syncGraphBlocking
            Monolithic update -> modifyLocalGraph update

          -- Note that we call these after doing the 'update', which creates
          -- pool versions for the IO pools. The reason for this is that
          -- 'createIMeta', at least, generates additional disks for use in the
          -- imeta pool. Currently there is no marker on disks to distinguish
          -- which pool they should be in, however, so if these are created
          -- before the update then they get added to the IO pool. The correct
          -- solution will involve proper support for multiple pools and
          -- multiple types of pools. In the meantime, creating these fake
          -- devices later works.
          M0.createMDPoolPVer filesystem

          M0.createIMeta filesystem
          validateConf

    if null (G.connectedTo Cluster Has rg :: [Cas.Rack])
    then load `catch` ( err "Failure during initial data load: "
                      . (show :: SomeException -> String) )
    else err "" "Initial data is already loaded."

goRack_XXX0 :: CI.Rack_XXX0 -> PhaseM RC l ()
goRack_XXX0 CI.Rack_XXX0{..} = do
    let rack = Cas.Rack rack_idx_XXX0
    HW.registerRack rack
    mapM_ (goEnc_XXX0 rack) rack_enclosures_XXX0

goEnc_XXX0 :: Cas.Rack -> CI.Enclosure_XXX0 -> PhaseM RC l ()
goEnc_XXX0 rack CI.Enclosure_XXX0{..} = do
    let encl = Cas.Enclosure enc_id_XXX0
    HW.registerEnclosure rack encl
    mapM_ (HW.registerBMC encl) enc_bmc_XXX0
    mapM_ (goHost_XXX0 encl) enc_hosts_XXX0

goHost_XXX0 :: Cas.Enclosure -> CI.Host_XXX0 -> PhaseM RC l ()
goHost_XXX0 enc CI.Host_XXX0{..} = do
    let host = Cas.Host (T.unpack h_fqdn_XXX0)
    HW.registerHost host
    HW.locateHostInEnclosure host enc
    -- Nodes mentioned in ID are not clients in the 'dynamic' sense.
    HW.unsetHostAttr host Cas.HA_M0CLIENT
