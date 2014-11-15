{-# LANGUAGE DeriveDataTypeable #-}

module Data.Some (Some(..)) where

import Data.Typeable (Typeable)

-- | An auxiliary type for hiding parameters of type constructors
data Some f = forall a. Some (f a) deriving (Typeable)
