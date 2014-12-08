-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- Various utilities for passing around instances as first-class
-- values over the network.
--

{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

{-# OPTIONS_GHC -fno-warn-orphans #-} -- for Typeable Typeable

module Network.CEP.Instances where

import Data.Typeable (Typeable)
import Control.Distributed.Process (Static)

data Some ctx f where
    Precisely :: forall ctx f a. ctx a => !(f a) -> Some ctx f
  deriving (Typeable)

some :: (forall a. ctx a => f a -> b) -> Some ctx f -> b
some f (Precisely x) = f x

class Boring a where
instance Boring a
deriving instance Typeable Boring

type Some' = Some Boring

data Instance ctx a where
    Instance :: ctx a => Instance ctx a
  deriving (Typeable)

data (:&:) f g a = (:&:) (f a) (g a)
  deriving (Typeable)

class ctx a => Statically ctx a where
  staticInstance :: Static (Instance (Statically ctx) a)

deriving instance Typeable Statically
