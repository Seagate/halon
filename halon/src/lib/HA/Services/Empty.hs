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

{-# OPTIONS_GHC -fno-warn-orphans      #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Empty
  ( EmptyConf(..)
  , HA.Services.Empty.__remoteTable
  , configDictEmptyConf
  , configDictEmptyConf__static
  ) where

import Data.Hashable
import Data.Typeable
import GHC.Generics

import HA.Aeson
import HA.SafeCopy
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

$(generateDicts ''EmptyConf)
$(deriveService ''EmptyConf 'emptySchema [])
deriveSafeCopy 0 'base ''EmptyConf
