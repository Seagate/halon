{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module    : HA.RecoveryCoordinator.Actions.Storage
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Store any 'Typeable' value in 'Storage' for later retrieval.
--
-- TODO: Use "Data.Dynamic" which does the same thing instead of manually coercing?
module HA.RecoveryCoordinator.RC.Internal.Storage
  ( Storage
  , empty
  , put
  , get
  , delete
  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Typeable
import           GHC.Exts
import           Unsafe.Coerce

-- | 'TypeRep' indexed 'Map' storing ('put') any 'Typeable' value
-- through help of 'unsafeCoerce'.
newtype Storage = Storage (Map TypeRep Any)

-- | Create empty storage.
empty :: Storage
empty = Storage Map.empty

-- | Put a value inside storage.
put :: Typeable a => a -> Storage -> Storage
put x (Storage k) = Storage $ Map.insert (typeOf x) (unsafeCoerce x) k

-- | Get a value out of storage.
get :: forall a . Typeable a => Storage -> Maybe a
get (Storage k) = unsafeCoerce <$> Map.lookup (typeRep (Proxy :: Proxy a)) k

-- | Remove from of storage.
delete :: Typeable a => Proxy a -> Storage -> Storage
delete p (Storage k) = Storage $ Map.delete (typeRep p) k
