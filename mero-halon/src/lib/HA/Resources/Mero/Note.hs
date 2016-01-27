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
data ConfObjectState
    = M0_NC_UNKNOWN
    | M0_NC_ONLINE
    | M0_NC_FAILED
    | M0_NC_TRANSIENT
    | M0_NC_REPAIR
    | M0_NC_REPAIRING
    | M0_NC_REBALANCE
    deriving (Eq, Show, Enum, Typeable, Generic)

instance Binary ConfObjectState
instance Hashable ConfObjectState

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(mkDicts
  [ ''ConfObjectState ]
  [ (''R.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Node, ''Is, ''ConfObjectState)
  , (''M0.Process, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''ConfObjectState)
  , (''M0.Disk, ''Is, ''ConfObjectState)
  , (''M0.SDev, ''Is, ''ConfObjectState)
  , (''R.StorageDevice, ''Is, ''ConfObjectState) ]
  )

$(mkResRel
  [ ''ConfObjectState ]
  [ (''R.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Node, ''Is, ''ConfObjectState)
  , (''M0.Process, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''ConfObjectState)
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
