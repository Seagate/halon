-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero notification specific resources.

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators              #-}

{-# OPTIONS_GHC -fno-warn-orphans       #-}

module HA.Resources.Mero.Note where

import HA.Resources (Cluster, Has(..))
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor as R
import HA.Resources.TH
import Mero.ConfC (Fid(..))

import Data.Binary (Binary)
import Data.Bits (shiftR)
import Data.Hashable (Hashable)
import GHC.Generics (Generic)
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Typeable (Typeable)
import Data.Proxy (Proxy(..))
import Data.Word ( Word64 )

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
    deriving (Eq, Show, Enum, Typeable, Generic, Ord)

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
  [ (''Cluster, ''Has, ''PrincipalRM)
  , (''M0.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Node, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''PrincipalRM)
  , (''M0.Disk, ''Is, ''ConfObjectState)
  , (''M0.SDev, ''Is, ''ConfObjectState)
  , (''M0.Pool, ''Is, ''ConfObjectState)
  , (''R.StorageDevice, ''Is, ''ConfObjectState) ]
  )

$(mkResRel
  [ ''ConfObjectState, ''PrincipalRM ]
  [ (''Cluster, ''Has, ''PrincipalRM)
  , (''M0.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Node, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''PrincipalRM)
  , (''M0.Disk, ''Is, ''ConfObjectState)
  , (''M0.SDev, ''Is, ''ConfObjectState)
  , (''M0.Pool, ''Is, ''ConfObjectState)
  , (''R.StorageDevice, ''Is, ''ConfObjectState) ]
  []
  )

--------------------------------------------------------------------------------
-- Specific object state                                                      --
--------------------------------------------------------------------------------

instance HasConfObjectState M0.Rack
instance HasConfObjectState M0.Enclosure
instance HasConfObjectState M0.Controller
instance HasConfObjectState M0.Node
instance HasConfObjectState M0.Process where
  getConfObjState x rg = case G.connectedTo x Is rg of
      [y] -> ms y
      _ -> M0_NC_ONLINE
    where
      ms M0.PSUnknown = M0_NC_UNKNOWN
      ms (M0.PSFailed _) = M0_NC_FAILED
      ms M0.PSOffline = M0_NC_FAILED
      ms M0.PSStarting = M0_NC_FAILED
      ms M0.PSStopping = M0_NC_FAILED
      ms M0.PSOnline = M0_NC_ONLINE
      ms (M0.PSInhibited M0.PSOnline) = M0_NC_TRANSIENT
      ms (M0.PSInhibited y) = ms y
instance HasConfObjectState M0.Service
instance HasConfObjectState M0.Disk
instance HasConfObjectState M0.SDev
instance HasConfObjectState M0.Pool

-- A dictionary wrapper for configuration objects
data SomeConfObjDict = forall x. (Typeable x, M0.ConfObj x, HasConfObjectState x)
  => SomeConfObjDict (Proxy x)

-- Yields the ConfObj dictionary of the object with the given Fid.
--
-- TODO: Generate this with TH.
fidConfObjDict :: Fid -> Maybe SomeConfObjDict
fidConfObjDict f = Map.lookup (f_container f `shiftR` (64 - 8)) dictMap

-- | Map of all dictionaries
dictMap :: Map.Map Word64 SomeConfObjDict
dictMap = Map.fromList
    [ mkTypePair (Proxy :: Proxy M0.Node)
    , mkTypePair (Proxy :: Proxy M0.Rack)
    , mkTypePair (Proxy :: Proxy M0.Pool)
    , mkTypePair (Proxy :: Proxy M0.Process)
    , mkTypePair (Proxy :: Proxy M0.Service)
    , mkTypePair (Proxy :: Proxy M0.SDev)
    , mkTypePair (Proxy :: Proxy M0.Enclosure)
    , mkTypePair (Proxy :: Proxy M0.Controller)
    , mkTypePair (Proxy :: Proxy M0.Disk)
    ]
  where
    mkTypePair :: forall a. (Typeable a, M0.ConfObj a, HasConfObjectState a)
               => Proxy a -> (Word64, SomeConfObjDict)
    mkTypePair a = (M0.fidType a, SomeConfObjDict (Proxy :: Proxy a))

-- | Class to determine configuration object state from the resource graph.
class (G.Resource a, M0.ConfObj a) => HasConfObjectState a where
  getConfObjState :: a -> G.Graph -> ConfObjectState
  default getConfObjState :: G.Relation Is a ConfObjectState
                          => a -> G.Graph -> ConfObjectState
  getConfObjState x rg = fromMaybe M0_NC_ONLINE
                          . listToMaybe $ G.connectedTo x Is rg

lookupConfObjectState :: G.Graph -> Fid -> Maybe ConfObjectState
lookupConfObjectState g fid = fidConfObjDict fid >>= \case
  SomeConfObjDict (_ :: Proxy ct0) -> do
    obj <- M0.lookupConfObjByFid fid g :: Maybe ct0
    return $ getConfObjState obj g

-- | Lookup the configuration object states of objects with the given FIDs.
lookupConfObjectStates :: [Fid] -> G.Graph -> [(Fid, ConfObjectState)]
lookupConfObjectStates fids g = catMaybes
    . fmap (traverse id)
    $ zip fids (lookupConfObjectState g <$> fids)
