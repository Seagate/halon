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

{-# OPTIONS_GHC -fno-warn-orphans       #-}

module HA.Resources.Mero.Note where

import HA.Resources
import HA.Resources.Castor
import HA.Resources.TH
import HA.ResourceGraph
  ( Resource(..)
  , Relation(..)
  , Dict(..)
  )
import Control.Distributed.Process.Closure

import Mero.ConfC (Fid(..))

import Data.Hashable (Hashable)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

newtype ConfObject = ConfObject
    { confObjectId   :: Fid
    } deriving (Eq, Show, Generic, Typeable)

instance Binary ConfObject
instance Hashable ConfObject

-- | Configuration object states. See "Requirements: Mero failure notification"
-- document for the semantics of each state.
data ConfObjectState
    = M0_NC_UNKNOWN
    | M0_NC_ONLINE
    | M0_NC_FAILED
    | M0_NC_TRANSIENT
    | M0_NC_REPAIR
    | M0_NC_REBALANCE
    deriving (Eq, Show, Enum, Typeable, Generic)

instance Binary ConfObjectState
instance Hashable ConfObjectState

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(mkDicts
  [ ''ConfObject, ''ConfObjectState]
  [ (''ConfObject, ''At, ''Node)
  , (''ConfObject, ''Is, ''ConfObjectState)
  ]
  )

$(mkResRel
  [ ''ConfObject, ''ConfObjectState]
  [ (''ConfObject, ''At, ''Node)
  , (''ConfObject, ''Is, ''ConfObjectState)
  ]
  []
  )
