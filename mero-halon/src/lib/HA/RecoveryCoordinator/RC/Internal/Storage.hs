-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE ScopedTypeVariables #-}
module HA.RecoveryCoordinator.RC.Internal.Storage
  ( Storage
  , empty
  , put
  , get
  , delete
  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Typeable

import GHC.Exts
import Unsafe.Coerce

newtype Storage = Storage (Map TypeRep Any)

-- | Create empty storage.
empty :: Storage
empty = Storage Map.empty

-- | Put a value inside storage.
put :: forall a . Typeable a => a -> Storage -> Storage
put x (Storage k) = Storage $ Map.insert (typeRep (Proxy :: Proxy a)) (unsafeCoerce x) k

-- | Get a value out of storage.
get :: forall a . Typeable a => Storage -> Maybe a
get (Storage k) = unsafeCoerce <$> Map.lookup (typeRep (Proxy :: Proxy a)) k

-- | Remove from of storage.
delete :: Typeable a => Proxy a -> Storage -> Storage
delete p (Storage k) = Storage $ Map.delete (typeRep p) k
