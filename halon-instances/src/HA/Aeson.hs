{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE PackageImports       #-}
{-# LANGUAGE QuasiQuotes          #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- |
-- Module    : HA.Aeson
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Halon wrapper around "Data.JSON",  This module should be imported
-- wherever 'FromJSON' 'ToJSON' are needed.
-- @aeson@ package should not be imported directly by users at all
-- as default generated 'ToJSON', 'FromJSON' instance will not do the right
-- thing.
--
-- Also provides some orphans instances.

module HA.Aeson 
  ( module Data.Aeson
  , module Data.Aeson.Types
  ) where

import Data.Aeson
import Data.Aeson.Types
import Data.UUID as UUID
import qualified Data.Text as Text
import qualified Data.ByteString.Char8 as B8
import Network.Transport (EndPointAddress(..))
import "distributed-process" Control.Distributed.Process (NodeId)

instance ToJSON UUID where
  toJSON uuid = Data.Aeson.String (UUID.toText uuid)

instance FromJSON UUID where
  parseJSON (String s) = do
    maybe (fail $ "UUID have incorrect format:  " ++ Text.unpack s)
          return $ UUID.fromText s
  parseJSON _ = fail "not a string"

instance ToJSON NodeId
instance FromJSON NodeId

instance ToJSON EndPointAddress where
  toJSON (EndPointAddress s) = toJSON (B8.unpack s)
instance FromJSON EndPointAddress where
  parseJSON s = EndPointAddress . B8.pack <$> parseJSON s
