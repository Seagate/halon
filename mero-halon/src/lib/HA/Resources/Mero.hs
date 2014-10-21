-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Mero specific resources.

{-# LANGUAGE MagicHash #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Resources.Mero where

import HA.Resources
import HA.ResourceGraph
  ( Resource(..)
  , Relation(..)
  , Dict(..)
  )
import Control.Distributed.Process.Closure

import Data.Hashable (Hashable)
import Data.Binary (Binary)
import Data.Word (Word64)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | Configuration object identifiers.
data UUID = UUID {-# UNPACK #-} !Word64
                 {-# UNPACK #-} !Word64
    deriving (Eq, Ord, Show, Generic, Typeable)

instance Binary UUID
instance Hashable UUID

-- | Configuration objects types. Should match "conf/obj.h".
data ConfType
    = M0_CO_DIR         -- 0, unused
    | M0_CO_PROFILE     -- 1
    | M0_CO_FILESYSTEM  -- 2
    | M0_CO_SERVICE     -- 3
    | M0_CO_NODE        -- 4
    | M0_CO_NIC         -- 5
    | M0_CO_SDEV        -- 6
    | M0_CO_UNKNOWN Int
    deriving (Eq, Show, Generic, Typeable)

instance Binary ConfType
instance Hashable ConfType

data ConfObject = ConfObject
    { confObjectType :: ConfType
    , confObjectId   :: UUID
    } deriving (Eq, Show, Generic, Typeable)

instance Binary ConfObject
instance Hashable ConfObject

-- | Configuration object states. See "Requirements: Mero failure notification"
-- document for the semantics of each state.
data ConfObjectState
    = M0_NC_UNKNOWN
    | M0_NC_ACTIVE
    | M0_NC_FAILED
    | M0_NC_TRANSIENT
    | M0_NC_DEGRADED
    | M0_NC_RECOVERING
    | M0_NC_OFFLINE
    | M0_NC_ANATHEMISED
    deriving (Eq, Enum, Typeable, Generic)

instance Binary ConfObjectState
instance Hashable ConfObjectState

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | The relation between a configuration object and the runtime resource
-- representing it.
data At = At
    deriving (Eq, Show, Generic, Typeable)

instance Binary At
instance Hashable At

-- | The relation between a configuration object and its state marker.
data Is = Is
    deriving (Eq, Show, Generic, Typeable)

instance Binary Is
instance Hashable Is

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- XXX Only nodes and services have runtime information attached to them, for now.

resdict_ConfObject :: Dict (Resource ConfObject)
resdict_ConfObjectState :: Dict (Resource ConfObjectState)

resdict_ConfObject = Dict
resdict_ConfObjectState = Dict

reldict_At_ConfObject_Node :: Dict (Relation At ConfObject Node)
reldict_Is_ConfObject_ConfObjectState :: Dict (Relation Is ConfObject ConfObjectState)

reldict_At_ConfObject_Node = Dict
reldict_Is_ConfObject_ConfObjectState = Dict

remotable [ 'resdict_ConfObject
          , 'resdict_ConfObjectState
          , 'reldict_At_ConfObject_Node
          , 'reldict_Is_ConfObject_ConfObjectState ]

instance Resource ConfObject where
    resourceDict = $(mkStatic 'resdict_ConfObject)

instance Resource ConfObjectState where
    resourceDict = $(mkStatic 'resdict_ConfObjectState)

instance Relation At ConfObject Node where
    relationDict = $(mkStatic 'reldict_At_ConfObject_Node)

instance Relation Is ConfObject ConfObjectState where
    relationDict = $(mkStatic 'reldict_Is_ConfObject_ConfObjectState)
