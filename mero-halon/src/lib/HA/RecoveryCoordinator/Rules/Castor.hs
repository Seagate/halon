{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to Castor install of Mero.

module HA.RecoveryCoordinator.Rules.Castor where

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Mero
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
#ifdef USE_MERO
import HA.RecoveryCoordinator.Rules.Mero
#endif

import Network.CEP

castorRules :: Definitions LoopState ()
castorRules = do
    defineSimple "Initial-data-load" $ \(HAEvent _ CI.InitialData{..} _) -> do
      mapM_ goRack id_racks
#ifdef USE_MERO
      filesystem <- intialiseConfInRG
      loadMeroGlobals id_m0_globals
      loadMeroServers id_m0_servers
      failureSets <- generateFailureSets 2 2 1 -- TODO real values
      createPoolVersions filesystem failureSets
#endif
  where
    goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
      registerRack rack
      mapM_ (goEnc rack) rack_enclosures
    goEnc rack (CI.Enclosure{..}) = let
        enclosure = Enclosure enc_id
      in do
        registerEnclosure rack enclosure
        registerBMC enclosure enc_bmc
        mapM_ (goHost enclosure) enc_hosts
    goHost enc (CI.Host{..}) = let
        host = Host h_fqdn
        mem = fromIntegral h_memsize
        cpucount = fromIntegral h_cpucount
        attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount]
      in do
        registerHost host
        locateHostInEnclosure host enc
        mapM_ (setHostAttr host) attrs
        mapM_ (registerInterface host) h_interfaces

