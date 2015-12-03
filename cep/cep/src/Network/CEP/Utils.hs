{-# LANGUAGE ExistentialQuantification  #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
--
module Network.CEP.Utils where

data Some f = forall a. Some (f a)
