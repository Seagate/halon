-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero.Core where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0

import Mero.ConfC ( Fid )

import Data.Maybe (listToMaybe)
import Data.Proxy
import Data.Word ( Word64 )

import Network.CEP

import Prelude hiding (id)

-- | Atomically fetch a FID sequence number of increment the sequence count.
newFidSeq :: PhaseM LoopState l Word64
newFidSeq = getLocalGraph >>= \rg ->
    case G.connectedTo Cluster Has rg of
      ((M0.FidSeq w):_) -> go rg w
      [] -> go rg 0
  where
    go rg w = let
        w' = w + 1
        rg' = G.connectUniqueFrom Cluster Has (M0.FidSeq w') $ rg
      in do
        putLocalGraph rg'
        return w'

newFid :: M0.ConfObj a => Proxy a -> PhaseM LoopState l Fid
newFid p = newFidSeq >>= return . M0.fidInit p 1

--------------------------------------------------------------------------------
-- Core configuration
--------------------------------------------------------------------------------

getM0Globals :: PhaseM LoopState l (Maybe CI.M0Globals)
getM0Globals = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero globals."
  return . listToMaybe
    $ G.connectedTo Cluster Has rg

-- | Load Mero global data into the graph
loadMeroGlobals :: CI.M0Globals
                -> PhaseM LoopState l ()
loadMeroGlobals g = modifyLocalGraph $ return . G.connect Cluster Has g
