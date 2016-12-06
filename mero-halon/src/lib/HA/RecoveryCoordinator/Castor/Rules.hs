{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to Castor install of Mero.

module HA.RecoveryCoordinator.Castor.Rules where

import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.RC.Events.Cluster
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
#ifdef USE_MERO
import Control.Monad
import Control.Monad.Catch
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Mero.Actions.Failure
import qualified HA.RecoveryCoordinator.Castor.Process.Rules as Process
import qualified HA.RecoveryCoordinator.Castor.Drive as Drive
import qualified HA.RecoveryCoordinator.Castor.Filesystem as Filesystem
import qualified HA.RecoveryCoordinator.Castor.Service as Service
import qualified HA.RecoveryCoordinator.Castor.Expander.Rules as Expander
import qualified HA.RecoveryCoordinator.Castor.Node.Rules as Node
#endif
import Data.Foldable
import Data.Maybe

import Network.CEP
import Prelude hiding (id, (.))

lookupStorageDevicePathsInGraph :: StorageDevice -> G.Graph -> [String]
lookupStorageDevicePathsInGraph sd g =
    mapMaybe extractPath ids
  where
    ids = G.connectedTo sd Has g
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

castorRules :: Definitions RC ()
castorRules = sequence_
  [ ruleInitialDataLoad
#ifdef USE_MERO
  , Filesystem.rules
  , Process.rules
  , Drive.rules
  , Expander.rules
  , Node.rules
  , Service.rules
#endif
  ]

-- | Load initial data from facts file into the system.
--   TODO We could only use 'syncGraphBlocking' in the preloaded case.
ruleInitialDataLoad :: Definitions RC ()
ruleInitialDataLoad = defineSimpleTask "castor::initial-data-load" $ \CI.InitialData{..} -> do
  rg  <- getLocalGraph
  let racks  = G.connectedTo Cluster Has rg :: [Rack]
  if null racks
  then do
      mapM_ goRack id_racks
#ifdef USE_MERO
      (do filesystem <- initialiseConfInRG
          loadMeroGlobals id_m0_globals
          loadMeroServers filesystem id_m0_servers
          createMDPoolPVer filesystem
          graph <- getLocalGraph
          let runValidateConf = validateTransactionCache >>= \case
                Left e -> do
                  phaseLog "error" $ "Exception during conf validation: " ++ show e
                  putLocalGraph rg
                  notify $ InitialDataLoadFailed (show e)
                Right Nothing -> do
                  phaseLog "info" "Initial data loaded."
                  notify InitialDataLoaded
                Right (Just e) -> do
                  phaseLog "error" $ "Conf failed to validate: " ++ e
                  putLocalGraph rg
                  notify $ InitialDataLoadFailed e
          Just updateType <- getCurrentGraphUpdateType
          case updateType of
            Iterative update -> do
              phaseLog "warning" "iterative graph population - can't test sanity prior to update."
              let mupdate = update graph
              for_ mupdate $ \updateGraph -> do
                graph' <- updateGraph $ \rg' -> do
                  putLocalGraph rg'
                  syncGraphBlocking
                  getLocalGraph
                putLocalGraph graph'
                syncGraphBlocking
                runValidateConf
            Monolithic update -> do
              modifyLocalGraph update
              runValidateConf)
          `catch` (\e -> do
                      phaseLog "error" $ "Failure during initial data load: " ++ show (e::SomeException)
                      notify $ InitialDataLoadFailed (show e))
#else
      notify InitialDataLoaded
      phaseLog "info" "Initial data loaded."
#endif
  else do
    phaseLog "error" "Initial data is already loaded."
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
    host = Host h_fqdn
    mem = fromIntegral h_memsize
    cpucount = fromIntegral h_cpucount
    attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount]
    -- Nodes mentioned in ID are not clients in the 'dynamic' sense.
    remAttrs = [HA_M0CLIENT]
  in do
    registerHost host
    locateHostInEnclosure host enc
    mapM_ (setHostAttr host) attrs
    mapM_ (unsetHostAttr host) remAttrs
    mapM_ (registerInterface host) h_interfaces
