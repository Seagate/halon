-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HA.RecoveryCoordinator.Actions.Mero
  ( lookupConfObjByFid )
where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0

import Mero.ConfC (Fid)

import Data.Maybe (catMaybes, listToMaybe)
import Data.Typeable (cast)

import Network.CEP

lookupConfObjByFid :: forall a l. (G.Resource a, M0.ConfObj a)
                   => Fid
                   -> PhaseM LoopState l (Maybe a)
lookupConfObjByFid f = do
    phaseLog "rg-query" $ "Looking for conf objects with FID "
                        ++ show f
    rg <- getLocalGraph
    return . listToMaybe . filter (\x -> M0.fid x == f) $ allObjs rg
  where
    allObjs rg = catMaybes
               . fmap (\x -> cast x :: Maybe a)
               . fst . unzip
               $ G.getGraphResources rg
