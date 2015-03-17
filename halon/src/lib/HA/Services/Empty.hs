-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

{-# OPTIONS_GHC -fno-warn-orphans      #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Empty
  ( EmptyConf(..)
  , HA.Services.Empty.__remoteTable
  , configDictEmptyConf
  , configDictEmptyConf__static
  ) where

import Data.Binary
import Data.Hashable
import Data.Typeable
import GHC.Generics

import HA.Service.TH

import Control.Applicative (pure)

import Options.Schema

data EmptyConf = EmptyConf deriving (Eq, Generic, Show, Typeable)

instance Binary EmptyConf
instance Hashable EmptyConf

emptySchema :: Schema EmptyConf
emptySchema = pure EmptyConf

$(generateDicts ''EmptyConf)
$(deriveService ''EmptyConf 'emptySchema [])
