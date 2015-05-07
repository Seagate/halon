-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.ClusterMap where

import Data.Binary
import Data.Yaml

import GHC.Generics

data DevId = DevId { id :: Int, filename :: String }
  deriving (Eq, Show, Generic)

instance Binary DevId
instance FromJSON DevId where
  parseJSON (Object v) = DevId <$> v .: "id"
                               <*> v .: "filename"
  parseJSON _ = error "Can't parse DevId from Yaml"

data Devices = Devices [DevId]
  deriving (Eq, Show, Generic)

instance Binary Devices
instance FromJSON Devices where
  parseJSON (Object v) = Devices <$> v.: "Devices"
  parseJSON _ = error "Can't parse Devices from Yaml"
