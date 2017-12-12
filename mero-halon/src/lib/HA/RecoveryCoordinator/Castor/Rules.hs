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

module HA.RecoveryCoordinator.Castor.Rules (castorRules, goRack_XXX3) where

import           Control.Monad.Catch (catch, SomeException)
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
import qualified HA.Resources.Castor as R
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
        if null (G.connectedTo Cluster Has rg :: [R.Rack])
        then loadInitialData idata `catch`
            ( err "Failure during initial data load: "
            . (show :: SomeException -> String) )
        else err "" "Initial data is already loaded."
  where
    err :: String -> String -> PhaseM RC l ()
    err logPrefix msg = do
        Log.rcLog' Log.ERROR (logPrefix ++ msg)
        notify (InitialDataLoadFailed msg)

loadInitialData :: CI.InitialData -> PhaseM RC l ()
loadInitialData CI.InitialData{..} = do
    -- for_ _id_profiles goProfile
    for_ _id_racks goRack
    undefined -- XXX

-- goProfile :: CI.Profile -> PhaseM RC l ()
-- goProfile CI.Profile{..} = do
--     root <- M0.Root <$> newFidRC (Proxy :: Proxy M0.Root)
--     undefined -- XXX

goRack :: CI.Rack -> PhaseM RC l ()
goRack CI.Rack{..} =
    let rack = R.Rack rack_idx
    in do
        registerRack rack
        for_ rack_enclosures goEnclosure

goEnclosure :: CI.Enclosure -> PhaseM RC l ()
goEnclosure CI.Enclosure{..} = undefined -- XXX

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

        validateConf = validateTransactionCache >>= \case
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
          mapM_ goRack_XXX3 id_racks_XXX0
          filesystem <- initialiseConfInRG_XXX3
          loadMeroGlobals id_m0_globals_XXX0
          loadMeroServers filesystem id_m0_servers_XXX0
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
          createMDPoolPVer filesystem

          createIMeta filesystem
          validateConf

    if null (G.connectedTo Cluster Has rg :: [R.Rack_XXX1])
    then load `catch` ( err "Failure during initial data load: "
                      . (show :: SomeException -> String) )
    else err "" "Initial data is already loaded."

goRack_XXX3 :: CI.Rack_XXX0 -> PhaseM RC l ()
goRack_XXX3 CI.Rack_XXX0{..} = let rack = R.Rack_XXX1 rack_idx_XXX0 in do
  registerRack_XXX3 rack
  mapM_ (goEnc_XXX3 rack) rack_enclosures_XXX0

goEnc_XXX3 :: R.Rack_XXX1 -> CI.Enclosure_XXX0 -> PhaseM RC l ()
goEnc_XXX3 rack CI.Enclosure_XXX0{..} = let
    enclosure = R.Enclosure_XXX1 enc_id_XXX0
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc_XXX0
    mapM_ (goHost_XXX0 enclosure) enc_hosts_XXX0

goHost_XXX0 :: R.Enclosure_XXX1 -> CI.Host_XXX0 -> PhaseM RC l ()
goHost_XXX0 enc CI.Host_XXX0{..} = let
    host = R.Host_XXX1 $ T.unpack h_fqdn_XXX0
    -- Nodes mentioned in ID are not clients in the 'dynamic' sense.
    remAttrs = [R.HA_M0CLIENT]
  in do
    registerHost host
    locateHostInEnclosure host enc
    mapM_ (unsetHostAttr host) remAttrs
