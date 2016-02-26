-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero notification specific resources.

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators              #-}

{-# OPTIONS_GHC -fno-warn-orphans       #-}

module HA.Resources.Mero.Note where

import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor as R
import HA.Resources.TH
import Mero.ConfC (Fid(..))

import Data.Hashable (Hashable)
import Data.Binary (Binary)
import Data.List (nubBy)
import Data.Maybe (catMaybes, isJust)
import Data.Typeable (Typeable, cast, eqT, (:~:))
import Data.Proxy (Proxy(..))
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | Configuration object states. See "Requirements: Mero failure notification"
-- document for the semantics of each state.
--
-- See @mero/ha/note.h:m0_ha_obj_state@ for the mero definition of
-- this structure
data ConfObjectState
    = M0_NC_UNKNOWN
      -- ^ Object state unknown
    | M0_NC_ONLINE
      -- ^ Object can be used normally
    | M0_NC_FAILED
      -- ^ Object has experienced a permanent failure and cannot be
      -- recovered.
    | M0_NC_TRANSIENT
      -- ^ Object is experiencing a temporary failure. Halon will
      -- notify Mero when the object is available for use again.
    | M0_NC_REPAIR
      -- ^ This state is only applicable to the pool objects. In this
      -- state, the pool is undergoing repair, i.e., the process of
      -- reconstructing data lost due to a failure and storing them in
      -- spare space.
    | M0_NC_REPAIRED
      -- ^ This state is only applicable to the pool objects. In this
      -- state, the pool device has completed sns repair. Its data is
      -- re-constructed on its corresponding spare space.
    | M0_NC_REBALANCE
      -- ^ This state is only applicable to the pool objects.
      -- Rebalance process is complementary to repair: previously
      -- reconstructed data is being copied from spare space to the
      -- replacement storage.
    deriving (Eq, Show, Enum, Typeable, Generic)

instance Binary ConfObjectState
instance Hashable ConfObjectState

-- | Marker for the principal RM service
data PrincipalRM = PrincipalRM
  deriving (Eq, Show, Enum, Typeable, Generic)

instance Binary PrincipalRM
instance Hashable PrincipalRM

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(mkDicts
  [ ''ConfObjectState, ''PrincipalRM]
  [ (''R.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Node, ''Is, ''ConfObjectState)
  , (''M0.Process, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''PrincipalRM)
  , (''M0.Disk, ''Is, ''ConfObjectState)
  , (''M0.SDev, ''Is, ''ConfObjectState)
  , (''R.StorageDevice, ''Is, ''ConfObjectState) ]
  )

$(mkResRel
  [ ''ConfObjectState, ''PrincipalRM ]
  [ (''R.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Node, ''Is, ''ConfObjectState)
  , (''M0.Process, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''PrincipalRM)
  , (''M0.Disk, ''Is, ''ConfObjectState)
  , (''M0.SDev, ''Is, ''ConfObjectState)
  , (''R.StorageDevice, ''Is, ''ConfObjectState) ]
  []
  )

-- | Lookup the configuration object states of objects with the given FIDs.
rgLookupConfObjectStates :: [Fid] -> G.Graph -> [(Fid, ConfObjectState)]
rgLookupConfObjectStates fids g =
    [ (fid, state)
    | (res, rels) <- G.getGraphResources g
    , fid : _     <- [catMaybes $ map (tryGetFid res) fidDicts]
    , elem fid fids
    , state : _   <- [(catMaybes $ map findConfObjectState rels)++[M0_NC_ONLINE]]
    ]
  where
    fidDicts = nubBy sameDicts $ concat $ map M0.fidConfObjDict fids
    sameDicts (M0.SomeConfObjDict (_ :: Proxy ct0))
              (M0.SomeConfObjDict (_ :: Proxy ct1)) =
      isJust (eqT :: Maybe (ct0 :~: ct1))

    tryGetFid (G.Res x) (M0.SomeConfObjDict (_ :: Proxy ct)) =
        M0.fid <$> (cast x :: Maybe ct)
    findConfObjectState (G.OutRel x _ b) | Just R.Is <- cast x = cast b
    findConfObjectState _                                      = Nothing
