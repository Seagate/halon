-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero.Core where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0

import Mero.ConfC ( Fid )
import Mero.M0Worker

import Control.Monad.IO.Class
import Data.Maybe (listToMaybe)
import Data.Proxy
import Data.Word ( Word64 )

import Network.CEP

import Prelude hiding (id)

newFidSeq :: G.Graph -> (Word64, G.Graph)
newFidSeq rg = case G.connectedTo Cluster Has rg of
    ((M0.FidSeq w):_) -> go w
    [] -> go 0
  where
    go w = let w' = w + 1
               rg' = G.connectUniqueFrom Cluster Has (M0.FidSeq w') $ rg
           in (w, rg')

-- | Atomically fetch a FID sequence number of increment the sequence count.
newFidSeqRC :: PhaseM LoopState l Word64
newFidSeqRC = do
  rg <- getLocalGraph
  let (w, rg') = newFidSeq rg
  putLocalGraph rg'
  return w

newFid :: M0.ConfObj a => Proxy a -> G.Graph -> (Fid, G.Graph)
newFid p rg = (M0.fidInit p 1 w, rg') where
  (w, rg') = newFidSeq rg

newFidRC :: M0.ConfObj a => Proxy a -> PhaseM LoopState l Fid
newFidRC p = M0.fidInit p 1 <$> newFidSeqRC

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

-- | Run the given computation in the m0 thread dedicated to the RC.
--
-- Some operations the RC submits cannot use the global m0 worker ('liftGlobalM0') because
-- they would require grabbing the global m0 worker a second time thus blocking the application.
-- Currently, these are spiel operations which use the notification interface before returning
-- control to the caller.
liftM0RC :: IO a -> PhaseM LoopState l (Maybe a)
liftM0RC task = getStorageRC >>= traverse (\worker -> liftIO $ runOnM0Worker worker task)

withM0RC :: ((forall a . IO a -> PhaseM LoopState l a) -> PhaseM LoopState l b) -> PhaseM LoopState l b
withM0RC f = getStorageRC >>= \case
  Nothing -> error "No worker loaded."
  Just w  -> f (liftIO . runOnM0Worker w)
