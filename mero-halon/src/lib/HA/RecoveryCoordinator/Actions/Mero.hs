-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HA.RecoveryCoordinator.Actions.Mero
  ( getFilesystem
  , lookupConfObjByFid
  )
where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
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
    return . listToMaybe . filter ((== f) . M0.fid) $ allObjs rg
  where
    allObjs rg = catMaybes
               . fmap (\x -> cast x :: Maybe a)
               . fst . unzip
               $ G.getGraphResources rg

getFilesystem :: PhaseM LoopState l (Maybe M0.Filesystem)
getFilesystem = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero filesystem."
  return . listToMaybe
    $ [ fs | p <- G.connectedTo Cluster Has rg :: [M0.Profile]
           , fs <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem]
      ]
