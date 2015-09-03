{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules and primitives specific to Mero

module HA.RecoveryCoordinator.Rules.Mero where

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Mero
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import HA.Resources
import qualified HA.ResourceGraph as G
import HA.Services.Mero.CEP (loadMeroServers)

import Control.Category (id, (>>>))

import Network.CEP

import Prelude hiding (id)

loadMeroServers :: [CI.M0Host]
                -> PhaseM LoopState l ()
loadMeroServers = mapM_ goHost where
  goHost CI.M0Host{..} = let
      host = Host m0h_fqdn
      m0host = M0Host m0h_fqdn m0h_mem_as m0h_mem_rss
                      m0h_mem_stack m0h_mem_memlock
                      m0h_cores

    in modifyLocalGraph $ \rg -> do
      return  $ newResource host
            >>> newResource m0host
            >>> connect host Has m0host
            >>> (foldl' (.) id $ fmap (goSrv m0host) m0h_services)
            >>> (foldl' (.) id $ fmap (goDev m0host) m0h_devices)
              $ rg

  goSrv host svc = do
        newResource svc
    >>> connect host Has svc

  goDev host dev = do
        newResource dev
    >>> connect host Has dev
