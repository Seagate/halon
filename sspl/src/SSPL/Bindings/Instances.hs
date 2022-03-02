-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module SSPL.Bindings.Instances where

import           Data.Aeson
import           Data.Binary
import           Data.Hashable       (Hashable)
import           Data.HashMap.Lazy
import           Data.SafeCopy
import           Data.Scientific
import           Data.Text.Binary ()
import           Data.Vector.Binary ()

import           GHC.Generics        (Generic)

instance (Eq k, Hashable k, Binary k, Binary v) => Binary (HashMap k v) where
  put x = put (Data.HashMap.Lazy.toList x)
  get = Data.HashMap.Lazy.fromList <$> get

-- We don't really expect HashMaps to suddenly change between upgrades
-- anyway…
instance (Eq k, Hashable k, Binary k, Binary v) => SafeCopy (HashMap k v) where
  putCopy = contain . safePut . Data.Binary.encode
  getCopy = contain $ Data.Binary.decode <$> safeGet
  kind = primitive

instance Binary Value

deriveSafeCopy 0 'primitive ''Scientific
deriveSafeCopy 0 'primitive ''Value
