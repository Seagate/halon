{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Module    : HA.Resources.Castor.Initial
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- No longer used "HA.Resources.Castor.Initial" resources. Used for migration.
module HA.Resources.Castor.Initial.Old
  ( Interface(..)
  , __resourcesTable
  , __remoteTable
  ) where

import           Control.Distributed.Process.Closure (remotable)
import           Data.Data (Data)
import           Data.Hashable (Hashable)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.Aeson
import qualified HA.Resources as R
import qualified HA.Resources.Castor as C
import           HA.Resources.TH
import           HA.SafeCopy

-- | Type of network 'Interface'.
data Network = Data | Management | Local
  deriving (Eq, Data, Generic, Show, Typeable)
instance ToJSON Network
instance Hashable Network

-- | Network interface on the 'Host'.
data Interface = Interface {
    if_macAddress :: String
  , if_network :: Network
  , if_ipAddrs :: [String]
} deriving (Eq, Data, Generic, Show, Typeable)
instance ToJSON Interface
instance Hashable Interface

deriveSafeCopy 0 'base ''Interface
deriveSafeCopy 0 'base ''Network
storageIndex ''Interface "9d4812ee-d1c9-455b-9e27-e146bb1c17e5"

mkStorageDicts [''Interface] [(''C.Host, ''R.Has, ''Interface)]

remotable [ mkStorageResourceName ''Interface
          , mkStorageRelationName (''C.Host, ''R.Has, ''Interface)
          ]

snd <$> mkStorageResource ''Interface
snd <$> mkStorageRelation (''C.Host, ''R.Has, ''Interface)
mkStorageResourceTable [''Interface] [(''C.Host, ''R.Has, ''Interface)]
