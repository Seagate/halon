-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module SSPL.Bindings.Instances where

import           Control.Applicative

import           Data.Aeson
import           Data.Binary ()
import           Data.Binary
import           Data.Hashable       (Hashable)
import           Data.HashMap.Lazy
import           Data.Scientific
import           Data.Text.Binary    ()
import           Data.Vector.Binary          ()

import           GHC.Generics        (Generic)

instance (Eq k, Hashable k, Binary k, Binary v) => Binary (HashMap k v) where
  put x = put (Data.HashMap.Lazy.toList x)
  get = Data.HashMap.Lazy.fromList <$> get

instance Binary Scientific where
  put x = put $ toRational x
  get = fromRational <$> get

deriving instance Generic Value
instance Binary Value
