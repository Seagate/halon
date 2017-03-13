-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE CPP                   #-}
module HA.Services.Empty
  ( EmptyConf(..)
  , HA.Services.Empty.__remoteTable
  , HA.Services.Empty.__resourcesTable
  , configDictEmptyConf
  , configDictEmptyConf__static
  ) where

import Data.Hashable
import Data.Typeable
import GHC.Generics

import HA.Aeson
import HA.SafeCopy
import HA.ResourceGraph
import HA.Service
import HA.Service.TH


#if ! MIN_VERSION_base(4,8,0)
import Control.Applicative (pure)
#endif

import Options.Schema

data EmptyConf = EmptyConf deriving (Eq, Generic, Show, Typeable)

instance Hashable EmptyConf
instance ToJSON EmptyConf

emptySchema :: Schema EmptyConf
emptySchema = pure EmptyConf

instance StorageIndex EmptyConf where
  typeKey _ = $(mkUUID "06073e0c-f4b8-4131-8d7d-eb402bd93451")
instance StorageIndex (Service EmptyConf) where
  typeKey _ = $(mkUUID "8356ffc4-99ee-4c77-a3f1-6423bd8d79ab")
$(generateDicts ''EmptyConf)
$(deriveService ''EmptyConf 'emptySchema [])
deriveSafeCopy 0 'base ''EmptyConf
