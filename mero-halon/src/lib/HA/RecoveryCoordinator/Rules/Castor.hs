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

import HA.Encode (decodeP)
import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
#ifdef USE_MERO
import Control.Applicative
import Control.Monad.Catch
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Events.Cluster
import HA.RecoveryCoordinator.Actions.Mero.Failure
import qualified HA.RecoveryCoordinator.Rules.Castor.Process as Process
import qualified HA.RecoveryCoordinator.Castor.Drive as Disk
import qualified HA.RecoveryCoordinator.Rules.Castor.Expander as Expander
import qualified HA.RecoveryCoordinator.Rules.Castor.Node as Node
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Repair as Repair
import HA.RecoveryCoordinator.Rules.Mero.Conf
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Events.Mero
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState (Note(..))
#endif
import Data.Foldable
import Control.Category


import Control.Monad
import Data.Maybe

import Network.CEP
import Prelude hiding (id, (.))

lookupStorageDevicePathsInGraph :: StorageDevice -> G.Graph -> [String]
lookupStorageDevicePathsInGraph sd g =
    mapMaybe extractPath $ ids
  where
    ids = G.connectedTo sd Has g
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

castorRules :: Definitions LoopState ()
castorRules = sequence_
  [ ruleInitialDataLoad
#ifdef USE_MERO
  , setStateChangeHandlers
  , ruleMeroNoteSet
  , ruleInternalStateChangeHandler
  , ruleGetEntryPoint
  , Process.rules
  , Disk.rules
  , Expander.rules
  , Node.rules
#endif
  ]

-- | Load initial data from facts file into the system.
--   TODO We could only use 'syncGraphBlocking' in the preloaded case.
ruleInitialDataLoad :: Definitions LoopState ()
ruleInitialDataLoad = defineSimple "Initial-data-load" $ \(HAEvent eid CI.InitialData{..} _) -> do
  racks <- do rg <- getLocalGraph
              return (G.connectedTo Cluster Has rg :: [Rack])
  if null racks
  then do
      mapM_ goRack id_racks
      syncGraphBlocking
#ifdef USE_MERO
      (do filesystem <- initialiseConfInRG
          loadMeroGlobals id_m0_globals
          loadMeroServers filesystem id_m0_servers
          createMDPoolPVer filesystem
          graph <- getLocalGraph
          syncGraphBlocking
          Just strategy <- getCurrentStrategy
          let update = onInit strategy graph
          for_ update $ \updateGraph -> do
            graph' <- updateGraph $ \rg -> do
              putLocalGraph rg
              syncGraphBlocking
              getLocalGraph
            putLocalGraph graph'
            syncGraphBlocking
          (if isJust update then liftProcess else registerSyncGraph) $
            say "Loaded initial data")
          `catch` (\e -> phaseLog "error" $ "Failure during initial data load: " ++ show (e::SomeException))
      notify InitialDataLoaded
#else
      liftProcess $ say "Loaded initial data"
#endif
  else phaseLog "error" "Initial data is already loaded."
  messageProcessed eid

#ifdef USE_MERO
setStateChangeHandlers :: Definitions LoopState ()
setStateChangeHandlers = do
    define "castor::internal-state-change-controller::set" $ do
      setThem <- phaseHandle "set"
      finish <- phaseHandle "finish"
      directly setThem $ do
        putStorageRC $ ExternalNotificationHandlers stateChangeHandlersE
        putStorageRC $ InternalNotificationHandlers stateChangeHandlersI
        continue finish

      directly finish stop

      start setThem ()
  where
    stateChangeHandlersE = concat
      [ Disk.externalNotificationHandlers ]
    stateChangeHandlersI = concat
      [ Disk.internalNotificationHandlers ]

ruleMeroNoteSet :: Definitions LoopState ()
ruleMeroNoteSet = do
  defineSimpleTask "castor::mero-note-set" $ \(Set ns) -> do
    phaseLog "info" $ "Received " ++ show (Set ns)
    mhandlers <- getStorageRC
    traverse_ (traverse_ ($ Set ns) . getExternalNotificationHandlers) mhandlers
  Repair.querySpiel
  Repair.querySpielHourly

ruleInternalStateChangeHandler :: Definitions LoopState ()
ruleInternalStateChangeHandler = do
  defineSimpleTask "castor::internal-state-change-controller::run" $ \msg ->
    liftProcess (decodeP msg) >>= \(InternalObjectStateChange changes) -> let
        -- XXX: Using mapMaybe is a hack here to workound the problem
        -- that same event could be sent multiple times without
        -- actual state change.
        notes = mapMaybe extractNote changes
        s = Set notes
        extractNote (AnyStateChange a old new _)
          | old == new = Nothing
          | otherwise  = Just $ Note (M0.fid a) (toConfObjState a new)
      in unless (null notes) $ do
        mhandlers <- getStorageRC
        traverse_ (traverse_ ($ s) . getInternalNotificationHandlers) mhandlers

-- | Timeout between entrypoint retry.
entryPointTimeout :: Int
entryPointTimeout = 1 -- 1s

-- | Load information that is required to complete transaction from
-- resource graph.
ruleGetEntryPoint :: Definitions LoopState ()
ruleGetEntryPoint = define "castor::cluster::entry-point-request" $ do
  main <- phaseHandle "main"
  loop <- phaseHandle "loop"
  setPhase main $ \(HAEvent uuid (GetSpielAddress pid) _) -> do
    phaseLog "info" $ "Spiel Address requested."
    phaseLog "info" $ "requested.pid = " ++ show pid
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
    logEP (Just (M0.SpielAddress confd_fids confd_eps rm_fid rm_ep)) = do
       phaseLog "info" $ "confd.fids = " ++ show confd_fids
       phaseLog "info" $ "confd.eps  = " ++ show confd_eps
       phaseLog "info" $ "rm.fids    = " ++ show rm_fid
       phaseLog "info" $ "rm.ep      = " ++ show rm_ep
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
