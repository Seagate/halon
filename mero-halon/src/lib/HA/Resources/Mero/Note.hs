-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero notification specific resources.

{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StaticPointers             #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

module HA.Resources.Mero.Note where

import HA.Resources (Cluster, Has(..))
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note.TH
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor as R
import HA.Resources.TH
import Mero.ConfC (Fid(..))

import Control.Distributed.Static (Static, staticPtr)
import Control.Monad (join)

import Data.Aeson (FromJSON, ToJSON)
import Data.Binary (Binary)
import Data.Constraint (Dict)
import Data.Bits (shiftR)
import Data.Hashable (Hashable)
import Data.List (foldl')
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)
import Data.Proxy (Proxy(..))
import Data.Word ( Word64 )

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
    deriving (Eq, Show, Enum, Typeable, Generic, Ord)

instance Binary ConfObjectState
instance Hashable ConfObjectState
instance ToJSON ConfObjectState
instance FromJSON ConfObjectState

prettyConfObjState :: ConfObjectState -> String
prettyConfObjState M0_NC_UNKNOWN   = "N/A"
prettyConfObjState M0_NC_ONLINE    = "online"
prettyConfObjState M0_NC_FAILED    = "failed"
prettyConfObjState M0_NC_TRANSIENT = "transient"
prettyConfObjState M0_NC_REPAIR    = "repair"
prettyConfObjState M0_NC_REPAIRED  = "repaired"
prettyConfObjState M0_NC_REBALANCE = "rebalance"

-- | Marker for the principal RM service
data PrincipalRM = PrincipalRM
  deriving (Eq, Show, Enum, Typeable, Generic)

instance Binary PrincipalRM
instance Hashable PrincipalRM

--------------------------------------------------------------------------------
-- Specific object state                                                      --
--------------------------------------------------------------------------------

-- | Dictionary for carrying some object state.
data SomeHasConfObjectStateDict = forall a.
    SomeHasConfObjectStateDict (Dict (HasConfObjectState a))
  deriving Typeable

-- | Necessary for making this static.
someHasConfObjectStateDict :: Dict (HasConfObjectState a)
                           -> SomeHasConfObjectStateDict
someHasConfObjectStateDict = SomeHasConfObjectStateDict

-- | Class to determine configuration object state from the resource graph.
class (G.Resource a, M0.ConfObj a, Binary (StateCarrier a), Eq (StateCarrier a), Typeable (StateCarrier a))
  => HasConfObjectState a where
    type StateCarrier a :: *
    type StateCarrier a = ConfObjectState

    -- | Dictionary providing evidence of this class
    hasStateDict :: Static (Dict (HasConfObjectState a))

    getConfObjState :: a -> G.Graph -> ConfObjectState
    getConfObjState x rg = toConfObjState x $ getState x rg

    setState :: a -> StateCarrier a -> G.Graph -> G.Graph
    default setState :: G.Relation Is a ConfObjectState
                     => a -> ConfObjectState -> G.Graph -> G.Graph
    setState x st = G.connectUniqueFrom x Is st

    getState :: a -> G.Graph -> StateCarrier a
    default getState :: G.Relation Is a ConfObjectState
                     => a -> G.Graph -> ConfObjectState
    getState x rg = fromMaybe M0_NC_ONLINE
                            . listToMaybe $ G.connectedTo x Is rg

    toConfObjState :: a -> StateCarrier a -> ConfObjectState
    default toConfObjState  :: a -> StateCarrier a -> StateCarrier a
    toConfObjState = const id

-- | Associated type used where we carry no explicit state for a type.
data NoExplicitConfigState = NoExplicitConfigState
  deriving (Eq, Generic, Typeable, Show)
instance Binary NoExplicitConfigState

-- A dictionary wrapper for configuration objects
data SomeConfObjDict = forall x. (Typeable x, M0.ConfObj x, HasConfObjectState x)
  => SomeConfObjDict (Proxy x)

-- | Generate dictionaries
$(join <$> (mapM (mkDict ''HasConfObjectState) $
  [ ''M0.Root
  , ''M0.Profile
  , ''M0.Filesystem
  , ''M0.Rack
  , ''M0.Enclosure
  , ''M0.Controller
  , ''M0.Node
  , ''M0.Process
  , ''M0.Service
  , ''M0.Disk
  , ''M0.SDev
  , ''M0.Pool
  , ''M0.PVer
  , ''M0.RackV
  , ''M0.EnclosureV
  , ''M0.ControllerV
  , ''M0.DiskV
  ]))

instance HasConfObjectState M0.Root where
  type StateCarrier M0.Root = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Root
  toConfObjState _ = const M0_NC_ONLINE
instance HasConfObjectState M0.Profile where
  type StateCarrier M0.Profile = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Profile
  toConfObjState _ = const M0_NC_ONLINE
instance HasConfObjectState M0.Filesystem where
  type StateCarrier M0.Filesystem = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Filesystem
  toConfObjState _ = const M0_NC_ONLINE
instance HasConfObjectState M0.Rack where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Rack
instance HasConfObjectState M0.Enclosure where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Enclosure
instance HasConfObjectState M0.Controller where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Controller
instance HasConfObjectState M0.Node where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Node
instance HasConfObjectState M0.Process where
  type StateCarrier M0.Process = M0.ProcessState
  -- XXX: figure out why we need PSOnline here
  getState x rg = fromMaybe M0.PSUnknown . listToMaybe $ G.connectedTo x Is rg
  setState x st = G.connectUniqueFrom x Is st
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Process

  toConfObjState _ M0.PSUnknown = M0_NC_ONLINE
  toConfObjState _ (M0.PSFailed _) = M0_NC_FAILED
  toConfObjState _ M0.PSOffline = M0_NC_FAILED
  toConfObjState _ M0.PSStarting = M0_NC_FAILED
  toConfObjState _ M0.PSStopping = M0_NC_FAILED
  toConfObjState _ M0.PSOnline = M0_NC_ONLINE
  toConfObjState _ (M0.PSInhibited M0.PSOnline) = M0_NC_TRANSIENT
  toConfObjState x (M0.PSInhibited y) = toConfObjState x y

instance HasConfObjectState M0.Service where
  type StateCarrier M0.Service = M0.ServiceState
  getConfObjState x rg = case G.connectedTo x Is rg :: [M0.ServiceState] of
    y : _ -> toConfObjState x y
    _ -> M0_NC_ONLINE
  getState x rg = fromMaybe M0.SSUnknown . listToMaybe $ G.connectedTo x Is rg
  setState x st = G.connectUniqueFrom x Is st
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Service

  toConfObjState _ M0.SSUnknown = M0_NC_UNKNOWN
  toConfObjState _ M0.SSOffline = M0_NC_FAILED
  toConfObjState _ M0.SSFailed = M0_NC_FAILED
  toConfObjState _ M0.SSOnline = M0_NC_ONLINE
  -- TODO: Starting = ONLINE because mero hates non-online services
  -- during process start
  toConfObjState _ M0.SSStarting = M0_NC_ONLINE
  toConfObjState _ (M0.SSInhibited M0.SSOnline) = M0_NC_TRANSIENT
  toConfObjState x (M0.SSInhibited st) = toConfObjState x st

instance HasConfObjectState M0.Disk where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Disk
instance HasConfObjectState M0.SDev where
  type StateCarrier M0.SDev = ConfObjectState
  getState x rg = fromMaybe M0_NC_ONLINE . listToMaybe $
    [ st
    | (disk :: M0.Disk) <- G.connectedTo x M0.IsOnHardware rg
    , st <- G.connectedTo disk Is rg
    ]
  setState x st = \rg1 -> let
      disks = G.connectedTo x M0.IsOnHardware rg1 :: [M0.Disk]
      fun = foldl' (.) id $ (\d -> setState d st) <$> disks
    in fun rg1
  hasStateDict = staticPtr $ static dict_HasConfObjectState_SDev
instance HasConfObjectState M0.Pool where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Pool
instance HasConfObjectState M0.PVer where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_PVer
instance HasConfObjectState M0.RackV where
  type StateCarrier M0.RackV = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_RackV
  toConfObjState _ = const M0_NC_ONLINE
instance HasConfObjectState M0.EnclosureV where
  type StateCarrier M0.EnclosureV = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_EnclosureV
  toConfObjState _ = const M0_NC_ONLINE
instance HasConfObjectState M0.ControllerV where
  type StateCarrier M0.ControllerV = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_ControllerV
  toConfObjState _ = const M0_NC_ONLINE
instance HasConfObjectState M0.DiskV where
  type StateCarrier M0.DiskV = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_DiskV
  toConfObjState _ = const M0_NC_ONLINE

-- Yields the ConfObj dictionary of the object with the given Fid.
--
-- TODO: Generate this with TH.
fidConfObjDict :: Fid -> [SomeConfObjDict]
fidConfObjDict f = fromMaybe []
  $ Map.lookup (f_container f `shiftR` (64 - 8)) dictMap

-- | Map of all dictionaries
dictMap :: Map.Map Word64 [SomeConfObjDict]
dictMap = Map.fromListWith (<>) . fmap (fmap (: [])) $
    [ mkTypePair (Proxy :: Proxy M0.Root)
    , mkTypePair (Proxy :: Proxy M0.Profile)
    , mkTypePair (Proxy :: Proxy M0.Filesystem)
    , mkTypePair (Proxy :: Proxy M0.Node)
    , mkTypePair (Proxy :: Proxy M0.Rack)
    , mkTypePair (Proxy :: Proxy M0.Pool)
    , mkTypePair (Proxy :: Proxy M0.Process)
    , mkTypePair (Proxy :: Proxy M0.Service)
    , mkTypePair (Proxy :: Proxy M0.SDev)
    , mkTypePair (Proxy :: Proxy M0.Enclosure)
    , mkTypePair (Proxy :: Proxy M0.Controller)
    , mkTypePair (Proxy :: Proxy M0.Disk)
    , mkTypePair (Proxy :: Proxy M0.PVer)
    , mkTypePair (Proxy :: Proxy M0.RackV)
    , mkTypePair (Proxy :: Proxy M0.EnclosureV)
    , mkTypePair (Proxy :: Proxy M0.ControllerV)
    , mkTypePair (Proxy :: Proxy M0.DiskV)
    ]
  where
    mkTypePair :: forall a. (Typeable a, M0.ConfObj a, HasConfObjectState a)
               => Proxy a -> (Word64, SomeConfObjDict)
    mkTypePair a = (M0.fidType a, SomeConfObjDict (Proxy :: Proxy a))

lookupConfObjectState :: G.Graph -> Fid -> Maybe ConfObjectState
lookupConfObjectState g fid = listToMaybe $ mapMaybe go $ fidConfObjDict fid where
  go (SomeConfObjDict (_ :: Proxy ct0)) = do
      obj <- M0.lookupConfObjByFid fid g :: Maybe ct0
      return $ getConfObjState obj g

-- | Lookup the configuration object states of objects with the given FIDs.
lookupConfObjectStates :: [Fid] -> G.Graph -> [(Fid, ConfObjectState)]
lookupConfObjectStates fids g = catMaybes
    . fmap (traverse id)
    $ zip fids (lookupConfObjectState g <$> fids)
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
  , (''M0.Service, ''Is, ''PrincipalRM)
  , (''M0.Disk, ''Is, ''ConfObjectState)
  , (''M0.Pool, ''Is, ''ConfObjectState)
  , (''M0.PVer, ''Is, ''ConfObjectState)
  , (''R.StorageDevice, ''Is, ''ConfObjectState) ]
  )

$(mkResRel
  [ ''ConfObjectState, ''PrincipalRM ]
  [ (''Cluster, ''Has, ''PrincipalRM)
  , (''M0.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Node, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''PrincipalRM)
  , (''M0.Disk, ''Is, ''ConfObjectState)
  , (''M0.Pool, ''Is, ''ConfObjectState)
  , (''M0.PVer, ''Is, ''ConfObjectState)
  , (''R.StorageDevice, ''Is, ''ConfObjectState) ]
  []
  )
