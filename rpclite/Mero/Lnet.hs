{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright:  (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Supporting module for LNet
module Mero.Lnet
  ( TransportType(..)
  , LNid(..)
  , Endpoint(..)
  , encodeEndpoint
  , readEndpoint
  , readLNid
    -- * Attoparsec parsers
  , endpointParser
  , lnidParser
  ) where

import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A (typeMismatch)
import Data.Attoparsec.Text
import Data.Data
import Data.Hashable (Hashable)
import Data.SafeCopy (base, deriveSafeCopy)
import qualified Data.Text as T
import qualified Data.Text.Lazy as T (toStrict)
import qualified Data.Text.Lazy.Builder as TB
import qualified Data.Text.Lazy.Builder.Int as TB
import Data.Functor
import Data.Monoid ((<>))
import GHC.Generics (Generic)

-- | Network transport type.
data TransportType =
    O2IB -- ^ Infiniband
  | TCP -- ^ TCP
  deriving (Data, Eq, Generic, Show)

instance Hashable TransportType

-- | LNet LNID
data LNid =
    Loopback
  | IPNet T.Text TransportType
  deriving (Data, Eq, Generic, Show)

instance Hashable LNid

instance A.ToJSON LNid where
  toJSON ep = A.String . encodeLNid $ ep

instance A.FromJSON LNid where
  parseJSON (A.String ep) = case readLNid ep of
    Left err -> fail $ "Cannot parse LNid: " ++ show err
    Right x -> return x
  parseJSON invalid = A.typeMismatch "LNid" invalid

-- Lnet endpoint.
--
-- Endpoint address format (ABNF):
--
-- endpoint = nid ":12345:" DIGIT+ ":" DIGIT+
-- ; <network id>:<process id>:<portal number>:<transfer machine id>
-- ;
-- nid      = "0@lo" / (ipv4addr  "@" ("tcp" / "o2ib") [DIGIT])
-- ipv4addr = 1*3DIGIT "." 1*3DIGIT "." 1*3DIGIT "." 1*3DIGIT ; 0..255
data Endpoint = Endpoint {
    network_id :: LNid
  , process_id :: Int
  , portal_number :: Int
  , transfer_machine_id :: Int
} deriving (Data, Eq, Generic, Show)

instance Hashable Endpoint

instance A.ToJSON Endpoint where
  toJSON ep = A.String . encodeEndpoint $ ep

instance A.FromJSON Endpoint where
  parseJSON (A.String ep) = case readEndpoint ep of
    Left err -> fail $ "Cannot parse endpoint: " ++ show err
    Right x -> return x
  parseJSON invalid = A.typeMismatch "Endpoint" invalid

-- | Read an endpoint from a string.
readEndpoint :: T.Text -> Either String Endpoint
readEndpoint = parseOnly endpointParser

-- | Read a lustre NID from a String.
readLNid :: T.Text -> Either String LNid
readLNid = parseOnly lnidParser

-- | Encode an endpoint as Text
encodeEndpoint :: Endpoint -> T.Text
encodeEndpoint ep = T.toStrict . TB.toLazyText
    $ TB.fromText (encodeLNid $ network_id ep)
    <> TB.singleton ':'
    <> TB.decimal (process_id ep)
    <> TB.singleton ':'
    <> TB.decimal (portal_number ep)
    <> TB.singleton ':'
    <> TB.decimal (transfer_machine_id ep)

-- | Encode a lustre network ID to Text
encodeLNid :: LNid -> T.Text
encodeLNid Loopback = "0@lo"
encodeLNid (IPNet bs tt) =
    bs <> T.singleton '@' <> encodeTT tt
  where
    encodeTT O2IB = "o2ib"
    encodeTT TCP = "tcp"

-- | Parse an endpoint from a 'ByteString'.
endpointParser :: Parser Endpoint
endpointParser = do
  nid <- lnidParser
  _ <- char ':'
  pid <- read <$> many1 digit
  _ <- char ':'
  portal <- read <$> many1 digit
  _ <- char ':'
  tmid <- read <$> many1 digit
  return $ Endpoint nid pid portal tmid

lnidParser :: Parser LNid
lnidParser = choice [
      string "0@lo" $> Loopback
    , IPNet <$> (takeWhile1 (/= '@') <* char '@')
            <*> parseTransportType
    ]
  where
    parseTransportType = choice [
        string "o2ib" $> O2IB
      , string "tcp" $> TCP
      ]

-- Safecopy splices
deriveSafeCopy 0 'base ''TransportType
deriveSafeCopy 0 'base ''LNid
deriveSafeCopy 0 'base ''Endpoint
