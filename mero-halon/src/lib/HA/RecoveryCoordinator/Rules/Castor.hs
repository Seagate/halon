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
import           HA.RecoveryCoordinator.Rules.Castor.Controller
import qualified HA.RecoveryCoordinator.Rules.Castor.Process as Process
import qualified HA.RecoveryCoordinator.Rules.Castor.Disk as Disk
import qualified HA.RecoveryCoordinator.Rules.Castor.Expander as Expander
import qualified HA.RecoveryCoordinator.Rules.Castor.Node as Node
import qualified HA.RecoveryCoordinator.Rules.Castor.Disk.Repair as Repair
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

-- | Lookup device paths for the given 'StorageDevice'.
lookupStorageDevicePathsInGraph :: StorageDevice -> G.Graph -> [String]
lookupStorageDevicePathsInGraph sd g =
    mapMaybe extractPath $ ids
  where
    ids = G.connectedTo sd Has g
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | Collection of default CASTOR rules.
castorRules :: Definitions LoopState ()
castorRules = sequence_
  [ ruleInitialDataLoad
#ifdef USE_MERO
  , setStateChangeHandlers
  , ruleMeroNoteSet
  , ruleInternalStateChangeHandler
  , ruleGetEntryPoint
  , ruleProcessFailControllerFail
  , ruleProcessOnlineControllerOnline
  , Process.rules
  , Disk.rules
  , Expander.rules
  , Node.rules
#endif
  ]

-- | Loads the given 'CI.InitialData', populating the resource graph.
--
-- This rule syncs the graph ('syncGraphBlocking') multiple times
-- throughout its run as for sufficiently big 'CI.InitialData',
-- replicating all the graph updates that are performed here may take
-- longer than it takes for the RC to renew the lease. This can result
-- in RC losing the lease. This was observed on machines with already
-- high I/O loads such as a terraform cluster on AWS.
ruleInitialDataLoad :: Definitions LoopState ()
ruleInitialDataLoad = defineSimpleTask "Initial-data-load" $ \(CI.InitialData{..}) -> do
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
          -- Pick a principal RM
          _ <- pickPrincipalRM
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
          (if isJust update then liftProcess else syncGraph) $
            say "Loaded initial data")
          `catch` (\e -> phaseLog "error" $ "Failure during initial data load: " ++ show (e::SomeException))
      notify InitialDataLoaded
#else
      liftProcess $ say "Loaded initial data"
#endif
  else phaseLog "error" "Initial data is already loaded."
  messageProcessed eid

#ifdef USE_MERO
-- | Sets state change handlers in the ephemeral state of the RC. This
-- rule does not wait for any message and runs only once per lifetime
-- of any single RC instance.
--
-- Using ephemeral storage allows us to modify the active handlers
-- dynamically if desired though this functionality is currently
-- unused.
setStateChangeHandlers :: Definitions LoopState ()
setStateChangeHandlers = do
    define "set-state-change-handlers" $ do
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

-- | A small collection of rules interested in the 'Set' messages
-- received through the notification interface. Notably, this inlines
-- the rule in charge of dispatching external notification handlers
-- ('getExternalNotificationHandlers') on the 'Set'.
ruleMeroNoteSet :: Definitions LoopState ()
ruleMeroNoteSet = do
  defineSimpleTask "mero-note-set" $ \(Set ns) -> do
    phaseLog "info" $ "Received " ++ show (Set ns)
    mhandlers <- getStorageRC
    traverse_ (traverse_ ($ Set ns) . getExternalNotificationHandlers) mhandlers
  Repair.querySpiel
  Repair.querySpielHourly

-- | Converts 'InternalObjectStateChange' to a format expected by
-- internal notification handlers ('getInternalNotificationHandlers')
-- and runs the handlers.
ruleInternalStateChangeHandler :: Definitions LoopState ()
ruleInternalStateChangeHandler = do
  defineSimpleTask "internal-state-change-controller" $ \msg ->
    liftProcess (decodeP msg) >>= \(InternalObjectStateChange changes) -> let
        s = Set $ extractNote <$> changes
        extractNote (AnyStateChange a _old new _) =
          Note (M0.fid a) (toConfObjState a new)
      in do
        mhandlers <- getStorageRC
        traverse_ (traverse_ ($ s) . getInternalNotificationHandlers) mhandlers
#endif

#ifdef USE_MERO
-- | Timeout between entrypoint retry in seconds.
entryPointTimeout :: Int
entryPointTimeout = 1 -- 1s

-- | Handles 'GetSpielAddress' requests. This rule waits until the
-- 'M0.SpielAddress' becomes available in the resource graph then
-- sends it to the requesting process.
ruleGetEntryPoint :: Definitions LoopState ()
ruleGetEntryPoint = define "castor-entry-point-request" $ do
  main <- phaseHandle "main"
  loop <- phaseHandle "loop"
  setPhase main $ \(HAEvent uuid (GetSpielAddress pid) _) -> do
    phaseLog "info" $ "SpielAddress requested by " ++ show pid
    ep <- getSpielAddressRC
    case ep of
      Nothing -> do
        put Local $ Just pid
        -- We process message here because in case of RC death,
        -- there will be timeout on the userside anyways.
        messageProcessed uuid
        continue (timeout entryPointTimeout loop)
      Just{} -> do
        phaseLog "entrypoint" $ show ep
        liftProcess $ usend pid ep
        messageProcessed uuid

  directly loop $ do
    Just pid <- get Local
    ep <- getSpielAddressRC
    case ep of
      Nothing -> do
        continue (timeout entryPointTimeout loop)
      Just{} -> do
        phaseLog "entrypoint" $ show ep
        liftProcess $ usend pid ep

  start main Nothing
#endif

-- | Registers 'CI.Rack' information into RG and dispatches
-- processing of the enclosures ('goEnc') associated with it
-- ('CI.rack_enclosures').
goRack :: CI.Rack -> PhaseM LoopState l ()
goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
  registerRack rack
  mapM_ (goEnc rack) rack_enclosures

-- | Register an 'Enclosure' in the given 'Rack' and in RG and dispatch host registration ('goHost') for the enclosure ('CI.enc_hosts').
goEnc :: Rack -> CI.Enclosure -> PhaseM LoopState l ()
goEnc rack (CI.Enclosure{..}) = let
    enclosure = Enclosure enc_id
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc
    mapM_ (goHost enclosure) enc_hosts

-- | Register the given 'CI.Host' in the 'Enclosure', set 'HostAttr's
-- and proceed to 'registerInterface's for the host ('h_interfaces').
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
