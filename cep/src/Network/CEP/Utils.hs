{-# LANGUAGE ExistentialQuantification  #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
--
module Network.CEP.Utils where

data Some f = forall a. Some (f a)
