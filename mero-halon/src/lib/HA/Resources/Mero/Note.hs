-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Mero notification specific resources.

{-# LANGUAGE DataKinds                  #-}
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
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE KindSignatures             #-}

module HA.Resources.Mero.Note where

import           HA.Aeson (FromJSON, ToJSON)
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster, Has(..))
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note.TH
import           HA.Resources.TH
import           HA.SafeCopy
import           Mero.ConfC (Fid(..))
import           Mero.Lnet

import           Control.Distributed.Static (Static, staticPtr)
import           Control.Monad (join)

import           Data.Binary (Binary)
import           Data.Constraint (Dict)
import           Data.Bits (shiftR)
import           Data.Hashable (Hashable)
import qualified Data.Map as Map
import           Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import           Data.Monoid ((<>))
import           Data.Typeable (Typeable)
import           Data.Proxy (Proxy(..))
import           Data.Word ( Word64 )

import           GHC.Generics (Generic, Rep, M1, D)
import qualified GHC.Generics as Generics

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
    deriving (Eq, Show, Enum, Typeable, Generic, Ord, Read)
storageIndex ''ConfObjectState "f0d27472-7f24-479f-b1f9-35a368492383"
deriveSafeCopy 0 'base ''ConfObjectState

instance Hashable ConfObjectState
instance ToJSON ConfObjectState
instance FromJSON ConfObjectState

-- | Pretty formatting of 'ConfObjectState'.
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

instance Hashable PrincipalRM
storageIndex ''PrincipalRM "255f8652-9723-4f12-83b7-696800afed77"
deriveSafeCopy 0 'base ''PrincipalRM
instance ToJSON PrincipalRM

-- | A notification for the following end-points has failed. We use
-- this message to fail the processes that failed to receive a
-- notification.
newtype NotifyFailureEndpoints = NotifyFailureEndpoints [Endpoint]
  deriving (Eq, Show, Typeable, Generic)

instance Hashable NotifyFailureEndpoints
storageIndex ''NotifyFailureEndpoints "b87496c2-8d09-48b5-b699-f84bc5e6cb06"
deriveSafeCopy 0 'base ''NotifyFailureEndpoints

--------------------------------------------------------------------------------
-- Printing objects in a nicer way                                            --
--------------------------------------------------------------------------------

-- | Pretty-printing for objects, targetted at mero objects.
class ShowFidObj a where
  showFid :: a -> String
  default showFid :: (Generic a, GShowType (Rep a), M0.ConfObj a) => a -> String
  showFid = genShowFid

-- | Generic pretty-printer for objects with 'Fid's.
genShowFid :: (M0.ConfObj a, Generic a, GShowType (Rep a)) => a -> String
genShowFid x = showType (Generics.from x) ++ "{" ++ show (M0.fid x) ++ "}"

-- | Generics helper class for type name retrieval.
class GShowType a where
  showType :: a b -> String

instance (Generics.Datatype d) => GShowType (M1 D d a) where
  showType x = Generics.datatypeName x

instance ShowFidObj M0.Root
instance ShowFidObj M0.Profile

instance ShowFidObj M0.Node
instance ShowFidObj M0.Process
instance ShowFidObj M0.Service
instance ShowFidObj M0.SDev

instance ShowFidObj M0.Site
instance ShowFidObj M0.Rack
instance ShowFidObj M0.Enclosure
instance ShowFidObj M0.Controller
instance ShowFidObj M0.Disk

instance ShowFidObj M0.Pool
instance ShowFidObj M0.PVer
instance ShowFidObj M0.SiteV
instance ShowFidObj M0.RackV
instance ShowFidObj M0.EnclosureV
instance ShowFidObj M0.ControllerV
instance ShowFidObj M0.DiskV

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

-- | Load configuration object state from the object.
getConfObjState :: HasConfObjectState a => a -> G.Graph -> ConfObjectState
getConfObjState x rg = toConfObjState x $ getState x rg

-- | Class to determine configuration object state from the resource graph.
class ( G.Resource a
      , Binary a
      , M0.ConfObj a
      , ShowFidObj a
      , Binary (StateCarrier a)
      , Eq (StateCarrier a)
      , Typeable (StateCarrier a)
      , Show (StateCarrier a)
      , Read (StateCarrier a)
      )
  => HasConfObjectState a where
    type StateCarrier a :: *
    type StateCarrier a = ConfObjectState

    -- | Dictionary providing evidence of this class
    hasStateDict :: Static (Dict (HasConfObjectState a))

    setState :: a -> StateCarrier a -> G.Graph -> G.Graph
    default setState :: ( G.Relation Is a ConfObjectState
                        , StateCarrier a ~ ConfObjectState)
                     => a -> StateCarrier a -> G.Graph -> G.Graph
    setState x st = G.connect x Is st

    getState :: a -> G.Graph -> StateCarrier a
    default getState :: ( G.CardinalityTo Is a ConfObjectState ~ 'AtMostOne
                        , G.Relation Is a ConfObjectState
                        , StateCarrier a ~ ConfObjectState
                        )
                     => a -> G.Graph -> StateCarrier a
    getState x rg = fromMaybe M0_NC_ONLINE $ G.connectedTo x Is rg

    toConfObjState :: a -> StateCarrier a -> ConfObjectState
    default toConfObjState :: ConfObjectState ~ StateCarrier a
                           => a -> StateCarrier a -> ConfObjectState
    toConfObjState = const id

-- | Associated type used where we carry no explicit state for a type.
data NoExplicitConfigState = NoExplicitConfigState
  deriving (Eq, Generic, Typeable, Show, Read)
instance Binary NoExplicitConfigState

-- | A dictionary wrapper for configuration objects.
data SomeConfObjDict = forall x. (Typeable x, M0.ConfObj x, HasConfObjectState x)
  => SomeConfObjDict (Proxy x)

-- | Generate dictionaries
$(join <$> (mapM (mkDict ''HasConfObjectState) $
  [ ''M0.Root
  , ''M0.Profile

  , ''M0.Node
  , ''M0.Process
  , ''M0.Service
  , ''M0.Disk
  , ''M0.SDev

  , ''M0.Site
  , ''M0.Rack
  , ''M0.Enclosure
  , ''M0.Controller

  , ''M0.Pool
  , ''M0.PVer
  , ''M0.SiteV
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
instance HasConfObjectState M0.Site where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Site
instance HasConfObjectState M0.Rack where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Rack
instance HasConfObjectState M0.Enclosure where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Enclosure
instance HasConfObjectState M0.Controller where
  type StateCarrier M0.Controller = M0.ControllerState
  getState x rg = fromMaybe M0.CSUnknown $ G.connectedTo x Is rg
  setState x st = G.connect x Is st
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Controller

  toConfObjState _ M0.CSUnknown = M0_NC_ONLINE
  toConfObjState _ M0.CSOnline = M0_NC_ONLINE
  toConfObjState _ M0.CSTransient = M0_NC_TRANSIENT
instance HasConfObjectState M0.Node where
  type StateCarrier M0.Node = M0.NodeState
  getState x rg = fromMaybe M0.NSUnknown $ G.connectedTo x Is rg
  setState x st = G.connect x Is st
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Node

  toConfObjState _ M0.NSUnknown = M0_NC_ONLINE
  toConfObjState _ M0.NSFailed  = M0_NC_TRANSIENT
  toConfObjState _ M0.NSFailedUnrecoverable = M0_NC_FAILED
  toConfObjState _ M0.NSOffline = M0_NC_FAILED
  toConfObjState _ M0.NSOnline  = M0_NC_ONLINE
  toConfObjState _ M0.NSRebalance  = M0_NC_REBALANCE
instance HasConfObjectState M0.Process where
  type StateCarrier M0.Process = M0.ProcessState
  getState x rg = fromMaybe M0.PSUnknown $ G.connectedTo x Is rg
  setState x st = G.connect x Is st
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Process

  toConfObjState _ M0.PSUnknown = M0_NC_ONLINE
  toConfObjState _ (M0.PSFailed _) = M0_NC_FAILED
  toConfObjState _ M0.PSOffline = M0_NC_FAILED
  toConfObjState _ M0.PSStarting = M0_NC_TRANSIENT
  toConfObjState _ M0.PSQuiescing = M0_NC_TRANSIENT
  toConfObjState _ M0.PSStopping = M0_NC_TRANSIENT
  toConfObjState _ M0.PSOnline = M0_NC_ONLINE
  toConfObjState _ (M0.PSInhibited M0.PSOnline) = M0_NC_TRANSIENT
  toConfObjState x (M0.PSInhibited y) = toConfObjState x y

instance HasConfObjectState M0.Service where
  type StateCarrier M0.Service = M0.ServiceState
  getState x rg = fromMaybe M0.SSUnknown $ G.connectedTo x Is rg
  setState x st = G.connect x Is st
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Service

  toConfObjState _ M0.SSUnknown = M0_NC_ONLINE
  toConfObjState _ M0.SSOffline = M0_NC_FAILED
  toConfObjState _ M0.SSFailed = M0_NC_FAILED
  toConfObjState _ M0.SSOnline = M0_NC_ONLINE
  toConfObjState _ M0.SSStopping = M0_NC_ONLINE
  -- TODO: Starting = ONLINE because mero hates non-online services
  -- during process start
  toConfObjState _ M0.SSStarting = M0_NC_ONLINE
  toConfObjState _ (M0.SSInhibited M0.SSFailed) = M0_NC_FAILED
  toConfObjState _ (M0.SSInhibited _) = M0_NC_TRANSIENT
instance HasConfObjectState M0.Disk where
  type StateCarrier M0.Disk = M0.SDevState
  getState x rg = fromMaybe M0.SDSUnknown . listToMaybe $
    [ st
    | Just (sdev :: M0.SDev) <-
        [G.connectedFrom M0.IsOnHardware x rg]
    , Just st <- [G.connectedTo sdev Is rg]
    ]
  setState x st = \rg1 -> let
      sdevs :: Maybe M0.SDev
      sdevs = G.connectedFrom M0.IsOnHardware x rg1
    in maybe id (`setState` st) sdevs $ rg1
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Disk

  toConfObjState _ x = toConfObjState (undefined :: M0.SDev) x
instance HasConfObjectState M0.SDev where
  type StateCarrier M0.SDev = M0.SDevState
  getState x rg = fromMaybe M0.SDSUnknown $ G.connectedTo x Is rg
  setState x st = G.connect x Is st
  hasStateDict = staticPtr $ static dict_HasConfObjectState_SDev

  toConfObjState _ M0.SDSUnknown = M0_NC_ONLINE
  toConfObjState _ M0.SDSOnline = M0_NC_ONLINE
  toConfObjState _ M0.SDSFailed = M0_NC_FAILED
  toConfObjState _ M0.SDSRepairing = M0_NC_REPAIR
  toConfObjState _ M0.SDSRepaired = M0_NC_REPAIRED
  toConfObjState _ M0.SDSRebalancing = M0_NC_REBALANCE
  toConfObjState _ (M0.SDSTransient M0.SDSFailed) = M0_NC_FAILED -- odd case
  toConfObjState _ (M0.SDSTransient M0.SDSRepairing) = M0_NC_REPAIR
  toConfObjState _ (M0.SDSTransient M0.SDSRepaired) = M0_NC_REPAIRED
  toConfObjState _ (M0.SDSTransient M0.SDSRebalancing) = M0_NC_REBALANCE
  toConfObjState _ (M0.SDSTransient _) = M0_NC_TRANSIENT
  toConfObjState _ (M0.SDSInhibited _) = M0_NC_TRANSIENT
instance HasConfObjectState M0.Pool where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_Pool
instance HasConfObjectState M0.PVer where
  hasStateDict = staticPtr $ static dict_HasConfObjectState_PVer
instance HasConfObjectState M0.SiteV where
  type StateCarrier M0.SiteV = NoExplicitConfigState
  getState _ _ = NoExplicitConfigState
  setState _ _ = id
  hasStateDict = staticPtr $ static dict_HasConfObjectState_SiteV
  toConfObjState _ = const M0_NC_ONLINE
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

-- | Yields the 'SomeConfObjDict's of the object with the given 'Fid'.
-- See 'dictMap'.
--
-- TODO: Generate this with TH.
fidConfObjDict :: Fid -> [SomeConfObjDict]
fidConfObjDict f = fromMaybe []
  $ Map.lookup (f_container f `shiftR` (64 - 8)) dictMap

-- | Map of all dictionaries
dictMap :: Map.Map Word64 [SomeConfObjDict]
dictMap = Map.fromListWith (<>) . fmap (fmap (:[])) $
    [ mkTypePair (Proxy :: Proxy M0.Root)
    , mkTypePair (Proxy :: Proxy M0.Profile)

    , mkTypePair (Proxy :: Proxy M0.Node)
    , mkTypePair (Proxy :: Proxy M0.Process)
    , mkTypePair (Proxy :: Proxy M0.Service)
    , mkTypePair (Proxy :: Proxy M0.SDev)

    , mkTypePair (Proxy :: Proxy M0.Site)
    , mkTypePair (Proxy :: Proxy M0.Rack)
    , mkTypePair (Proxy :: Proxy M0.Enclosure)
    , mkTypePair (Proxy :: Proxy M0.Controller)
    , mkTypePair (Proxy :: Proxy M0.Disk)

    , mkTypePair (Proxy :: Proxy M0.Pool)
    , mkTypePair (Proxy :: Proxy M0.PVer)
    , mkTypePair (Proxy :: Proxy M0.SiteV)
    , mkTypePair (Proxy :: Proxy M0.RackV)
    , mkTypePair (Proxy :: Proxy M0.EnclosureV)
    , mkTypePair (Proxy :: Proxy M0.ControllerV)
    , mkTypePair (Proxy :: Proxy M0.DiskV)
    ]
  where
    mkTypePair :: forall a. (HasConfObjectState a)
               => Proxy a -> (Word64, SomeConfObjDict)
    mkTypePair a = (M0.fidType a, SomeConfObjDict (Proxy :: Proxy a))

-- | Find the 'ConfObjectState' of the object with the given 'Fid'.
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
  [ ''ConfObjectState, ''PrincipalRM ]
  [ (''Cluster, ''Has, ''PrincipalRM)
  , (''M0.Site, ''Is, ''ConfObjectState)
  , (''M0.Rack, ''Is, ''ConfObjectState)
  , (''M0.Enclosure, ''Is, ''ConfObjectState)
  , (''M0.Controller, ''Is, ''ConfObjectState)
  , (''M0.Service, ''Is, ''PrincipalRM)
  , (''M0.Pool, ''Is, ''ConfObjectState)
  , (''M0.PVer, ''Is, ''ConfObjectState)
  ]
  )

$(mkResRel
  [ ''ConfObjectState, ''PrincipalRM ]
  [ (''Cluster, AtMostOne, ''Has, AtMostOne, ''PrincipalRM)
  , (''M0.Site, Unbounded, ''Is, AtMostOne, ''ConfObjectState)
  , (''M0.Rack, Unbounded, ''Is, AtMostOne, ''ConfObjectState)
  , (''M0.Enclosure, Unbounded, ''Is, AtMostOne, ''ConfObjectState)
  , (''M0.Controller, Unbounded, ''Is, AtMostOne, ''ConfObjectState)
  , (''M0.Service, AtMostOne, ''Is, AtMostOne, ''PrincipalRM)
  , (''M0.Pool, Unbounded, ''Is, AtMostOne, ''ConfObjectState)
  , (''M0.PVer, Unbounded, ''Is, AtMostOne, ''ConfObjectState)
  ]
  []
  )
