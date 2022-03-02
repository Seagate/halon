{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.Mero.Actions.Conf
  ( -- ** Get all objects of type
    getRoot
  , getProfiles
  , theProfile
  , getSDevPool
  , getM0ServicesRC
  , getChildren
  , getParents
    -- ** Lookup objects based on another
  , lookupConfObjByFid
  , lookupM0Enclosure
  , lookupHostHAAddress
    -- ** Other things
  , getPrincipalRM
  , getPrincipalRM'
  , isPrincipalRM
  , setPrincipalRMIfUnset
  , pickPrincipalRM
  , markSDevReplaced
  , unmarkSDevReplaced
    -- * Low level graph API
  , m0encToEnc
  , encToM0Enc
    -- * Other
  , lookupLocationSDev
  ) where

import           Control.Category ((>>>))
import           Data.Maybe (listToMaybe)
import           Data.Typeable (Typeable)
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Runs(..))
import           HA.Resources.Castor
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC (Fid, ServiceType(..))
import           Mero.Lnet
import           Network.CEP

-- | Lookup a configuration object by its Mero FID.
lookupConfObjByFid :: (G.Resource a, M0.ConfObj a, Typeable a)
                   => Fid
                   -> PhaseM RC l (Maybe a)
lookupConfObjByFid f = M0.lookupConfObjByFid f <$> getGraph

--------------------------------------------------------------------------------
-- Querying conf in RG
--------------------------------------------------------------------------------

-- | Get the top-level Mero configuration object.
getRoot :: PhaseM RC l (Maybe M0.Root)
getRoot = G.connectedTo Cluster Has <$> getGraph

-- | Fetch Mero 'Profile's in the system.
getProfiles :: PhaseM RC l [M0.Profile]
getProfiles = do
    rg <- getGraph
    pure [ prof
         | Just (root :: M0.Root) <- [G.connectedTo Cluster Has rg]
         , prof <- G.connectedTo root M0.IsParentOf rg
         ]

-- XXX-MULTIPOOLS: DELETEME
theProfile :: PhaseM RC l (Maybe M0.Profile)
theProfile = listToMaybe <$> getProfiles

-- | RC wrapper for 'getM0Services'.
getM0ServicesRC :: PhaseM RC l [M0.Service]
getM0ServicesRC = M0.getM0Services <$> getGraph

-- | Find a pool the given 'M0.SDev' belongs to.
--
-- Fails if multiple pools are found. Metadata pool are ignored.
getSDevPool :: M0.SDev -> PhaseM RC l M0.Pool
getSDevPool sdev = do
    rg <- getGraph
    let pools =
          [ pool
          | Just (disk :: M0.Disk) <- [G.connectedTo sdev M0.IsOnHardware rg]
          , diskv :: M0.DiskV <- G.connectedTo disk M0.IsRealOf rg
          , Just (ctrlv :: M0.ControllerV) <- [G.connectedFrom M0.IsParentOf diskv rg]
          , Just (enclv :: M0.EnclosureV) <- [G.connectedFrom M0.IsParentOf ctrlv rg]
          , Just (rackv :: M0.RackV) <- [G.connectedFrom M0.IsParentOf enclv rg]
          , Just (sitev :: M0.SiteV) <- [G.connectedFrom M0.IsParentOf rackv rg]
          , Just (pver :: M0.PVer) <- [G.connectedFrom M0.IsParentOf sitev rg]
          , Just (pool :: M0.Pool) <- [G.connectedFrom M0.IsParentOf pver rg]
          , M0.fid pool /= M0.rt_mdpool (M0.getM0Root rg)
          ]
    case pools of
      -- TODO throw a better exception
      [] -> error "getSDevPool: No pool found for sdev"
      [x] -> return x
      x:_ -> do
        -- XXX-MULTIPOOLS: This shouldn't be an error.
        Log.rcLog' Log.ERROR ("Multiple pools found for sdev!" :: String)
        return x

-- | Find 'M0.Enclosure' object associated with 'Enclosure'.
lookupM0Enclosure :: Enclosure -> PhaseM RC l (Maybe M0.Enclosure)
lookupM0Enclosure encl = G.connectedFrom M0.At encl <$> getGraph

-- | Lookup the HA endpoint to be used for the node. This is stored as the
--   endpoint for the HA service hosted by processes on that node. Whilst in
--   theory different processes might have different HA endpoints, in
--   practice this should not happen.
lookupHostHAAddress :: Host -> PhaseM RC l (Maybe Endpoint)
lookupHostHAAddress host = getGraph >>= \rg -> return $ listToMaybe
  [ ep
  | node :: M0.Node <- G.connectedTo host Runs rg
  , proc :: M0.Process <- G.connectedTo node M0.IsParentOf rg
  , svc :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
  , M0.s_type svc == CST_HA
  , ep <- M0.s_endpoints svc
  ]

-- | Get all children of the conf object.
getChildren :: forall a b l. G.Relation M0.IsParentOf a b
            => a -> PhaseM RC l [b]
getChildren obj = G.asUnbounded
                . G.connectedTo obj M0.IsParentOf <$> getGraph

-- | Get parents of the conf objects.
getParents :: forall a b l. G.Relation M0.IsParentOf a b
           => b -> PhaseM RC l [a]
getParents obj = G.asUnbounded
               . G.connectedFrom M0.IsParentOf obj <$> getGraph

-- | Test if a service is the principal RM service.
isPrincipalRM :: M0.Service -> PhaseM RC l Bool
isPrincipalRM svc = G.isConnected svc Is M0.PrincipalRM <$> getGraph

-- | Return 'M0.PrincipalRM' service. Return 'Nothing' if this service
--   is not 'M0.SSOnline'.
getPrincipalRM' :: G.Graph -> Maybe M0.Service
getPrincipalRM' rg = case G.connectedFrom Is M0.PrincipalRM rg of
  Just svc | M0.getState svc rg == M0.SSOnline -> Just svc
  _ -> Nothing

-- | Monadic version of 'getPrincipalRM''.
getPrincipalRM :: PhaseM RC l (Maybe M0.Service)
getPrincipalRM = getPrincipalRM' <$> getGraph

-- | Set the given 'M0.Service' to be the 'M0.PrincipalRM' if one is
-- not yet set. Returns the principal RM which becomes current: old
-- one if already set, new one otherwise.
setPrincipalRMIfUnset :: M0.Service
                      -> PhaseM RC l M0.Service
setPrincipalRMIfUnset svc = getPrincipalRM >>= \case
  Just rm -> return rm
  Nothing -> do
    Log.rcLog' Log.DEBUG $ "new principal RM: " ++ show svc
    modifyGraph $ G.connect Cluster Has M0.PrincipalRM
              >>> G.connect svc Is M0.PrincipalRM
    return svc

-- | Pick a Principal RM out of the available RM services.
pickPrincipalRM :: PhaseM RC l (Maybe M0.Service)
pickPrincipalRM = do
  rg <- getGraph
  let rms = [ svc
            | proc <- M0.getM0Processes rg
            , G.isConnected proc Is M0.PSOnline rg
            , let svcTypes = M0.s_type <$> G.connectedTo proc M0.IsParentOf rg
            , CST_CONFD `elem` svcTypes
            , svc :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
            , M0.s_type svc == CST_RMS
            ]
  Log.rcLog' Log.DEBUG $ "available RM services: " ++ show rms
  traverse setPrincipalRMIfUnset $ listToMaybe rms

-- | Lookup enclosure corresponding to Mero enclosure.
m0encToEnc :: M0.Enclosure -> G.Graph -> Maybe R.Enclosure
m0encToEnc m0enc rg = G.connectedTo m0enc M0.At rg

-- | Lookup Mero enclosure corresponding to enclosure.
encToM0Enc :: R.Enclosure -> G.Graph -> Maybe M0.Enclosure
encToM0Enc enc rg = G.connectedFrom M0.At enc rg

-- | Find 'M0.SDev' that associated with a given location.
lookupLocationSDev :: R.Slot -> PhaseM RC l (Maybe M0.SDev)
lookupLocationSDev loc = G.connectedFrom M0.At loc <$> getGraph

-- | Mark 'M0.SDev' as replaced, so it could be rebalanced if needed.
markSDevReplaced :: M0.SDev -> PhaseM RC l ()
markSDevReplaced sdev = modifyGraph $ \rg ->
  maybe rg (\disk -> G.connect (disk::M0.Disk) Is M0.Replaced rg)
  $ G.connectedTo sdev M0.IsOnHardware rg

-- | Mark 'M0.SDev' as replaced, so it could be rebalanced if needed.
unmarkSDevReplaced :: M0.SDev -> PhaseM RC l ()
unmarkSDevReplaced sdev = modifyGraph $ \rg ->
  maybe rg (\disk -> G.disconnect (disk::M0.Disk) Is M0.Replaced rg)
  $ G.connectedTo sdev M0.IsOnHardware rg
