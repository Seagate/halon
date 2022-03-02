{-# LANGUAGE ExistentialQuantification  #-}
-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
--
module Network.CEP.Utils where

data Some f = forall a. Some (f a)
