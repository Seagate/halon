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

module HA.RecoveryCoordinator.Castor.Rules (castorRules,goRack) where

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
import           HA.Resources
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
ruleInitialDataLoad = defineSimpleTask "castor::initial-data-load" $ \CI.InitialData{..} -> do
  rg  <- getLocalGraph
  let racks  = G.connectedTo Cluster Has rg :: [Rack]
      runValidateConf = validateTransactionCache >>= \case
        Left e -> do
          Log.rcLog' Log.ERROR $ "Exception during conf validation: " ++ show e
          putLocalGraph rg
          notify $ InitialDataLoadFailed (show e)
        Right Nothing -> do
          Log.rcLog' Log.DEBUG "Initial data loaded."
          notify InitialDataLoaded
        Right (Just e) -> do
          Log.rcLog' Log.ERROR $ "Conf failed to validate: " ++ e
          putLocalGraph rg
          notify $ InitialDataLoadFailed e
  if null racks
  then do
      mapM_ goRack id_racks
      (do filesystem <- initialiseConfInRG
          loadMeroGlobals id_m0_globals
          loadMeroServers filesystem id_m0_servers
          graph <- getLocalGraph
          Just updateType <- getCurrentGraphUpdateType
          case updateType of
            Iterative update -> do
              Log.rcLog' Log.WARN "iterative graph population - can't test sanity prior to update."
              let mupdate = update graph
              for_ mupdate $ \updateGraph -> do
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
          runValidateConf
        ) `catch` (\e -> do
            Log.rcLog' Log.ERROR $ "Failure during initial data load: " ++ show (e::SomeException)
            notify $ InitialDataLoadFailed (show e))
  else do
    Log.rcLog' Log.ERROR "Initial data is already loaded."
    notify $ InitialDataLoadFailed "Initial data is already loaded."

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
