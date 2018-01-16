{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.Actions.Conf
  ( -- ** Get all objects of type
    getProfile_XXX3
  , getFilesystem_XXX3
  , getSDevPool
  , getM0ServicesRC
  , getChildren
  , getParents
    -- ** Lookup objects based on another
  , lookupConfObjByFid
  , lookupEnclosureM0
  , lookupHostHAAddress
    -- ** Other things
  , getPrincipalRM
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
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC
  ( Fid
  , ServiceType(..)
  )
import           Mero.Lnet
import           Network.CEP

-- | Lookup a configuration object by its Mero FID.
lookupConfObjByFid :: (G.Resource a, M0.ConfObj a, Typeable a)
                   => Fid
                   -> PhaseM RC l (Maybe a)
lookupConfObjByFid f =
    fmap (M0.lookupConfObjByFid f) getLocalGraph

--------------------------------------------------------------------------------
-- Querying conf in RG
--------------------------------------------------------------------------------

-- | Fetch the Mero profile in the system. Currently, we
--   only support a single profile, though in future there
--   might be multiple profiles and this function will need
--   to change.
getProfile_XXX3 :: PhaseM RC l (Maybe M0.Profile_XXX3)
getProfile_XXX3 =
    G.connectedTo Cluster Has <$> getLocalGraph

-- | Fetch the Mero filesystem in the system. Currently, we
--   only support a single filesystem, though in future there
--   might be multiple filesystems and this function will need
--   to change.
getFilesystem_XXX3 :: PhaseM RC l (Maybe M0.Filesystem_XXX3)
getFilesystem_XXX3 = getLocalGraph >>= \rg -> do
  return . listToMaybe
    $ [ fs | Just p <- [G.connectedTo Cluster Has rg :: Maybe M0.Profile_XXX3]
           , fs <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem_XXX3]
      ]

-- | RC wrapper for 'getM0Services'.
getM0ServicesRC :: PhaseM RC l [M0.Service]
getM0ServicesRC = M0.getM0Services <$> getLocalGraph

-- | Find a pool the given 'M0.SDev' belongs to.
--
-- Fails if multiple pools are found. Metadata pool are ignored.
getSDevPool :: M0.SDev -> PhaseM RC l M0.Pool_XXX3
getSDevPool sdev = do
    rg <- getLocalGraph
    let ps =
          [ p
          | Just d  <- [G.connectedTo sdev M0.IsOnHardware rg :: Maybe M0.Disk]
          , dv <- G.connectedTo d M0.IsRealOf rg :: [M0.DiskV]
          , Just (ct :: M0.ControllerV) <- [G.connectedFrom M0.IsParentOf dv rg]
          , Just (ev :: M0.EnclosureV) <- [G.connectedFrom M0.IsParentOf ct rg]
          , Just rv <- [G.connectedFrom M0.IsParentOf ev rg :: Maybe M0.RackV]
          , Just pv <- [G.connectedFrom M0.IsParentOf rv rg :: Maybe M0.PVer]
          , Just (p :: M0.Pool_XXX3) <- [G.connectedFrom M0.IsParentOf pv rg]
          , Just (fs :: M0.Filesystem_XXX3) <- [G.connectedFrom M0.IsParentOf p rg]
          , M0.fid p /= M0.f_mdpool_fid fs
          ]
    case ps of
      -- TODO throw a better exception
      [] -> error "getSDevPool: No pool found for sdev."
      x:[] -> return x
      x:_ -> do
        Log.rcLog' Log.ERROR ("Multiple pools found for sdev!" :: String)
        return x

-- | Find 'M0.Enclosure' object associated with 'Enclosure'.
lookupEnclosureM0 :: Cas.Enclosure -> PhaseM RC l (Maybe M0.Enclosure)
lookupEnclosureM0 enc =
    G.connectedFrom M0.At enc <$> getLocalGraph

-- | Lookup the HA endpoint to be used for the node. This is stored as the
--   endpoint for the HA service hosted by processes on that node. Whilst in
--   theory different processes might have different HA endpoints, in
--   practice this should not happen.
lookupHostHAAddress :: Cas.Host -> PhaseM RC l (Maybe Endpoint)
lookupHostHAAddress host = getLocalGraph >>= \rg -> return $ listToMaybe
  [ ep
  | node <- G.connectedTo host Runs rg :: [M0.Node]
  , ps <- G.connectedTo node M0.IsParentOf rg :: [M0.Process]
  , svc <- G.connectedTo ps M0.IsParentOf rg :: [M0.Service]
  , M0.s_type svc == CST_HA
  , ep <- M0.s_endpoints svc
  ]

-- | Get all children of the conf object.
getChildren :: forall a b l. G.Relation M0.IsParentOf a b
            => a -> PhaseM RC l [b]
getChildren obj = G.asUnbounded
                . G.connectedTo obj M0.IsParentOf <$> getLocalGraph

-- | Get parents of the conf objects.
getParents :: forall a b l. G.Relation M0.IsParentOf a b
           => b -> PhaseM RC l [a]
getParents obj = G.asUnbounded
               . G.connectedFrom M0.IsParentOf obj <$> getLocalGraph

-- | Test if a service is the principal RM service
isPrincipalRM :: M0.Service
              -> PhaseM RC l Bool
isPrincipalRM svc = getLocalGraph >>=
  return . G.isConnected svc Is M0.PrincipalRM

-- | Get the 'M0.Service' that's serving as the current 'M0.PrincipalRM'.
getPrincipalRM :: PhaseM RC l (Maybe M0.Service)
getPrincipalRM = getLocalGraph >>= \rg ->
  return . listToMaybe
    . filter (\x -> M0.getState x rg == M0.SSOnline)
    $ G.connectedFrom Is M0.PrincipalRM rg

-- | Set the given 'M0.Service' to be the 'M0.PrincipalRM' if one is
-- not yet set. Returns the principal RM which becomes current: old
-- one if already set, new one otherwise.
setPrincipalRMIfUnset :: M0.Service
                      -> PhaseM RC l M0.Service
setPrincipalRMIfUnset svc = getPrincipalRM >>= \case
  Just rm -> return rm
  Nothing -> do
    modifyGraph $ G.connect Cluster Has M0.PrincipalRM
              >>> G.connect svc Is M0.PrincipalRM
    return svc

-- | Pick a Principal RM out of the available RM services.
pickPrincipalRM :: PhaseM RC l (Maybe M0.Service)
pickPrincipalRM = getLocalGraph >>= \g ->
  let rms =
        [ rm
        | Just (prof :: M0.Profile_XXX3) <- [G.connectedTo Cluster Has g]
        , (fs :: M0.Filesystem_XXX3) <- G.connectedTo prof M0.IsParentOf g
        , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf g
        , (proc :: M0.Process) <- G.connectedTo node M0.IsParentOf g
        , G.isConnected proc Is M0.PSOnline g
        , let srv_types = M0.s_type <$> (G.connectedTo proc M0.IsParentOf g)
        , CST_CONFD `elem` srv_types
        , rm <- G.connectedTo proc M0.IsParentOf g :: [M0.Service]
        , G.isConnected proc Is M0.PSOnline g
        , M0.s_type rm == CST_RMS
        ]
  in traverse setPrincipalRMIfUnset $ listToMaybe rms

-- | Lookup enclosure corresponding to Mero enclosure.
m0encToEnc :: M0.Enclosure -> G.Graph -> Maybe Cas.Enclosure
m0encToEnc m0enc rg = G.connectedTo m0enc M0.At rg

-- | Lookup Mero enclosure corresponding to enclosure.
encToM0Enc :: Cas.Enclosure -> G.Graph -> Maybe M0.Enclosure
encToM0Enc enc rg = G.connectedFrom M0.At enc rg

-- | Find 'M0.SDev' that associated with a given location.
lookupLocationSDev :: Cas.Slot -> PhaseM RC l (Maybe M0.SDev)
lookupLocationSDev loc = G.connectedFrom M0.At loc <$> getLocalGraph

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
