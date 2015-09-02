{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.Resources.Mero
  ( module HA.Resources.Mero
  , CI.M0Globals
  ) where

import HA.Resources
import HA.Resources.TH
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI

import Data.Binary (Binary)
import Data.Data (Data)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import Data.Word ( Word32, Word64 )

import GHC.Generics (Generic)

data M0Host = M0Host {
    m0h_fqdn :: String -- ^ FQDN of host this server is running on
  , m0h_mem_as :: Word64
  , m0h_mem_rss :: Word64
  , m0h_mem_stack :: Word64
  , m0h_mem_memlock :: Word64
  , m0h_cores :: Word32
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Host
instance Hashable M0Host

$(mkDicts
  [ ''CI.M0Globals, ''CI.M0Device, ''M0Host, ''CI.M0Service ]
  [ (''Host, ''Has, ''M0Host)
  , (''M0Host, ''Has, ''CI.M0Service)
  , (''M0Host, ''Has, ''CI.M0Device)
  , (''Cluster, ''Has, ''CI.M0Globals)
  ]
  )

$(mkResRel
  [ ''CI.M0Globals, ''CI.M0Device, ''M0Host, ''CI.M0Service ]
  [ (''Host, ''Has, ''M0Host)
  , (''M0Host, ''Has, ''CI.M0Service)
  , (''M0Host, ''Has, ''CI.M0Device)
  , (''Cluster, ''Has, ''CI.M0Globals)
  ]
  []
  )
