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

import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import HA.Resources.TH

import Data.Hashable (Hashable)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
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
    | M0_NC_REBALANCE
    deriving (Eq, Show, Enum, Typeable, Generic)

instance Binary ConfObjectState
instance Hashable ConfObjectState

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(mkDicts
  [ ''ConfObjectState ]
  [ (''M0.SDev, ''Is, ''ConfObjectState) ]
  )

$(mkResRel
  [ ''ConfObjectState ]
  [ (''M0.SDev, ''Is, ''ConfObjectState) ]
  []
  )
