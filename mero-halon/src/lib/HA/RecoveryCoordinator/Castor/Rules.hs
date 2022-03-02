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
-- Copyright : (C) 2015-)017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Rules specific to Castor install of Mero.

module HA.RecoveryCoordinator.Castor.Rules
 ( castorRules
 , goSite
 ) where

import           Control.Monad.Catch (SomeException, catch)
import qualified Data.Text as T

import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.RecoveryCoordinator.Castor.Commands as Commands
import qualified HA.RecoveryCoordinator.Castor.Drive as Drive
import qualified HA.RecoveryCoordinator.Castor.Expander.Rules as Expander
import qualified HA.RecoveryCoordinator.Castor.FilesystemStats as FStats
import qualified HA.RecoveryCoordinator.Castor.Node.Rules as Node
import qualified HA.RecoveryCoordinator.Castor.Process.Rules as Process
import qualified HA.RecoveryCoordinator.Castor.Service as Service
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
  , FStats.rules
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
          mapM_ goSite id_sites
          initialiseConfInRG
          loadMeroGlobals id_m0_globals
          loadMeroServers id_m0_servers
          loadMeroPools id_pools >>= loadMeroProfiles id_profiles
          validateConf

    if null (G.connectedTo Cluster Has rg :: [Site])
    then load `catch` ( err "Failure during initial data load: "
                      . (show :: SomeException -> String) )
    else err "" "Initial data is already loaded."

goSite :: CI.Site -> PhaseM RC l ()
goSite CI.Site{..} = do
    let site = Site site_idx
    registerSite site
    mapM_ (goRack site) site_racks

goRack :: Site -> CI.Rack -> PhaseM RC l ()
goRack site CI.Rack{..} = do
    let rack = Rack rack_idx
    registerRack site rack
    mapM_ (goEnc rack) rack_enclosures

goEnc :: Rack -> CI.Enclosure -> PhaseM RC l ()
goEnc rack CI.Enclosure{..} = do
    let encl = Enclosure enc_id
    registerEnclosure rack encl
    mapM_ (registerBMC encl) enc_bmc
    mapM_ (goHost encl) enc_hosts

goHost :: Enclosure -> CI.Host -> PhaseM RC l ()
goHost encl CI.Host{..} = do
    let host = Host (T.unpack h_fqdn)
    registerHost host
    locateHostInEnclosure host encl
    -- Nodes mentioned in InitialData are not clients in the "dynamic" sense.
    unsetHostAttr host HA_M0CLIENT
