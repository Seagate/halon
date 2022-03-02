-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

module Data.Lifted where

import Data.Typeable (Typeable)

-- | A partial order with a least element.
data Lifted a = Bottom | Ord a => Value a
    deriving (Typeable)

-- Some of the following instances need to be defined manually, rather than
-- derived, because above datatype definition not Haskell'98.

instance Eq (Lifted a) where
    Bottom == Bottom = True
    Value x == Value y = x == y
    _ == _ = False

instance Ord (Lifted a) where
    compare Bottom Bottom = EQ
    compare Bottom _ = LT
    compare _ Bottom = GT
    compare (Value x) (Value y) = compare x y

fromValue :: Lifted a -> a
fromValue Bottom = error "Lifted.fromValue: Bottom"
fromValue (Value x) = x
