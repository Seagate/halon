{-# LANGUAGE BangPatterns  #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- stability: experimental
--
-- Module for manipulation of messages which remain intelligible as long
-- as the type definitions of the values they contain don't change.
module Data.PersistMessage
  ( PersistMessage(..)
  , StablePrint(..)
  , stableprint
  , stableprintTypeRep
  , persistMessage
  , unwrapMessage
  ) where

import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString as BS (ByteString)
import Data.Binary (Binary(..), encode, decode)
import qualified Data.Text as T (pack, unpack)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Typeable
import Data.List
import Data.SafeCopy
import Data.Serialize (runGetLazy, runPutLazy)
import Data.UUID (UUID)
import Data.Function (on)
import GHC.Generics


-- | 'GHC.Fingerprint' analogue that identifies the modules and type names
-- of a type.
newtype StablePrint = StablePrint BS.ByteString
  deriving (Typeable, Generic, Ord, Eq, Binary)

instance Show StablePrint where
  show (StablePrint s) = "StablePrint " ++ T.unpack (decodeUtf8 s)

-- | Create stable fingerprint for any Typeable value.
stableprint :: Typeable a => a -> StablePrint
stableprint = stableprintTypeRep . typeOf

stableprintTypeRep :: TypeRep -> StablePrint
stableprintTypeRep = StablePrint . encodeUtf8 . T.pack . flip go ""
  where
    go :: TypeRep -> String -> String
    go tr acc = module_ ++ "|" ++ name_ ++ ">" ++
                 foldr (.) id (intersperse ('|':) $ map go args) acc
      where
        (tycon, args) = splitTyConApp tr
        module_ = tyConModule tycon
        name_   = tyConName tycon

-- | PersistMessages are identified with a UUID and can be decoded
-- by any program that agrees on the stableprint of the encoded values.
data PersistMessage = PersistMessage
  { persistMessageId :: UUID
  , persistMessagePrint :: StablePrint
  , persistMessagePayload :: ByteString
  } deriving (Typeable, Generic, Show)

instance Binary PersistMessage

instance Eq PersistMessage where
    (==) = (==) `on` persistMessageId

instance Ord PersistMessage where
    compare = compare `on` persistMessageId

persistMessage :: (SafeCopy a, Typeable a) => UUID -> a -> PersistMessage
persistMessage u a = PersistMessage u (stableprint a) (runPutLazy $ safePut a)

unwrapMessage :: forall a. (SafeCopy a, Typeable a) => PersistMessage -> Maybe a
unwrapMessage msg =
    if persistMessagePrint msg == stableprint (undefined :: a)
    then case runGetLazy safeGet $ persistMessagePayload msg of
      Left _err -> Nothing -- TODO: Might want to do something here?
      Right !m -> Just m
    else Nothing
