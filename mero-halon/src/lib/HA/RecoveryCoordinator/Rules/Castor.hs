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

module HA.RecoveryCoordinator.Rules.Castor where

import Control.Distributed.Process hiding (catch)

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
#ifdef USE_MERO
import Control.Monad
import Control.Monad.Catch
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Events.Cluster
import HA.RecoveryCoordinator.Actions.Mero.Failure
import qualified HA.RecoveryCoordinator.Rules.Castor.Process as Process
import qualified HA.RecoveryCoordinator.Castor.Drive as Drive
import qualified HA.RecoveryCoordinator.Castor.Filesystem as Filesystem
import qualified HA.RecoveryCoordinator.Castor.Service as Service
import qualified HA.RecoveryCoordinator.Rules.Castor.Expander as Expander
import qualified HA.RecoveryCoordinator.Rules.Castor.Node as Node
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Repair as Repair
import qualified HA.Resources.Mero as M0
import HA.RecoveryCoordinator.Events.Mero
import Mero.Notification hiding (notifyMero)
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

castorRules :: Definitions LoopState ()
castorRules = sequence_
  [ ruleInitialDataLoad
#ifdef USE_MERO
  , ruleGetEntryPoint
  , Filesystem.rules
  , Process.rules
  , Drive.rules
  , Expander.rules
  , Node.rules
  , Service.rules
  , Repair.querySpiel
  , Repair.querySpielHourly
#endif
  ]

-- | Load initial data from facts file into the system.
--   TODO We could only use 'syncGraphBlocking' in the preloaded case.
ruleInitialDataLoad :: Definitions LoopState ()
ruleInitialDataLoad = defineSimple "castor::initial-data-load" $ \(HAEvent eid CI.InitialData{..} _) -> do
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
          Just strategy <- getCurrentStrategy
          let updateType = onInit strategy
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
                notify InitialDataLoaded
              (if isJust mupdate then liftProcess else registerSyncGraph) $
                say "Loaded initial data"
            Monolithic update -> do
              modifyLocalGraph update
              eresult <- validateTransactionCache
              case eresult of
                Left e -> do
                 phaseLog "error" $ "Exception during validation: " ++ show e
                 modifyLocalGraph $ const $ return rg
                Right Nothing -> notify InitialDataLoaded
                Right (Just e) -> do
                 phaseLog "error" $ "Error in inital data: " ++ show e
                 modifyLocalGraph $ const $ return  rg)
          `catch` (\e -> phaseLog "error" $ "Failure during initial data load: " ++ show (e::SomeException))
#else
      liftProcess $ say "Loaded initial data"
#endif
  else phaseLog "error" "Initial data is already loaded."
  messageProcessed eid

#ifdef USE_MERO
-- | Timeout between entrypoint retry.
entryPointTimeout :: Int
entryPointTimeout = 1 -- 1s

-- | Load information that is required to complete transaction from
-- resource graph.
ruleGetEntryPoint :: Definitions LoopState ()
ruleGetEntryPoint = define "castor::cluster::entry-point-request" $ do
  main <- phaseHandle "main"
  loop <- phaseHandle "loop"
  setPhase main $ \(HAEvent uuid (GetSpielAddress fid profile pid) _) -> do
    phaseLog "info" $ "Spiel Address requested."
    phaseLog "info" $ "requester.fid = " ++ show fid
    phaseLog "info" $ "requester.profile = " ++ show profile
    ep <- getSpielAddressRC
    case ep of
      Nothing -> do
        put Local $ Just (pid,0::Int)
        -- We process message here because in case of RC death,
        -- there will be timeout on the userside anyways.
        messageProcessed uuid
        continue (timeout entryPointTimeout loop)
      Just{} -> do
        logEP ep
        liftProcess $ usend pid ep
        messageProcessed uuid

  directly loop $ do
    Just (pid, _) <- get Local
    ep <- getSpielAddressRC
    case ep of
      Nothing -> do
        continue (timeout entryPointTimeout loop)
      Just{} -> do
        logEP ep
        liftProcess $ usend pid ep

  start main Nothing
  where
    logEP Nothing = phaseLog "warning" "Entrypoint information not available."
    logEP (Just (M0.SpielAddress confd_fids confd_eps quorum rm_fid rm_ep)) = do
       phaseLog "confd.fids"   $ show confd_fids
       phaseLog "confd.eps"    $ show confd_eps
       phaseLog "confd.quorum" $ show quorum
       phaseLog "rm.fids"      $ show rm_fid
       phaseLog "rm.ep"        $ show rm_ep
#endif

goRack :: CI.Rack -> PhaseM LoopState l ()
goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
  registerRack rack
  mapM_ (goEnc rack) rack_enclosures

goEnc :: Rack -> CI.Enclosure -> PhaseM LoopState l ()
goEnc rack (CI.Enclosure{..}) = let
    enclosure = Enclosure enc_id
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc
    mapM_ (goHost enclosure) enc_hosts

goHost :: Enclosure -> CI.Host -> PhaseM LoopState l ()
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
