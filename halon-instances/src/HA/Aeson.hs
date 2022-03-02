{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE PackageImports             #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# OPTIONS_GHC -fno-warn-orphans       #-}
-- |
-- Module    : HA.Aeson
-- Copyright : (C) 2016-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
  , ByteString64(..)
  , getEncodedByteString64
  ) where

import "distributed-process" Control.Distributed.Process (NodeId, ProcessId)
import           Data.Aeson
import           Data.Aeson.Types
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as B8
import           Data.Data (Data, Typeable)
import           Data.Hashable (Hashable)
import           Data.String (IsString(..))
import           Data.Text.Encoding (decodeLatin1, encodeUtf8)
import           GHC.Generics (Generic)
import           Network.Transport (EndPointAddress(..))
import           HA.SafeCopy

instance ToJSON NodeId
instance FromJSON NodeId

instance ToJSON EndPointAddress where
  toJSON (EndPointAddress s) = toJSON (B8.unpack s)
instance FromJSON EndPointAddress where
  parseJSON s = EndPointAddress . B8.pack <$> parseJSON s

instance ToJSON ProcessId where
  toJSON = toJSON . show

-- * BS64 implementation modeled after futurice haskell-mega-repo
--   implementation (BSD3)

-- | Wrapper for 'BS.ByteString' providing 'ToJSON' and 'FromJSON'
-- instances.
newtype ByteString64 = BS64 { getByteString64 :: BS.ByteString }
  deriving (Show, Eq, Ord, Data, Typeable, Generic, Hashable)

-- | Retrieve 'BS.ByteString' that's base64 encoded.
getEncodedByteString64 :: ByteString64 -> BS.ByteString
getEncodedByteString64 = B64.encode . getByteString64

instance ToJSON ByteString64 where
  toJSON = toJSON . decodeLatin1 . getEncodedByteString64

instance FromJSON ByteString64 where
  parseJSON = withText "ByteString" $
    pure . BS64 . B64.decodeLenient . encodeUtf8

instance IsString ByteString64 where
  fromString = BS64 . Data.String.fromString

instance Monoid ByteString64 where
  mempty = BS64 mempty
  BS64 a `mappend` BS64 b  = BS64 $ a `mappend` b

deriveSafeCopy 0 'base ''ByteString64
