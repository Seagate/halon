-- |
-- Module: Test.Helpers
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
{-# LANGUAGE ScopedTypeVariables #-}
module Test.Helpers where

import Control.Distributed.Process hiding (unwrapMessage)
import Data.Maybe (catMaybes)
import Data.PersistMessage
import Data.Typeable
import HA.EventQueue
import HA.SafeCopy

import qualified Test.Tasty.HUnit as HU

assertBool :: String -> Bool -> Process ()
assertBool s b = liftIO $ HU.assertBool s b

assertEqual :: (Eq a, Show a) => String -> a -> a -> Process ()
assertEqual s a b = liftIO $ HU.assertEqual s a b

unPersistHAEvent :: (Monad m, Typeable a, SafeCopy a) => PersistMessage -> m (Maybe a)
unPersistHAEvent = return . fmap eventPayload . unwrapMessage

unPersistHAEvents :: (Typeable a, SafeCopy a, Monad m) => [PersistMessage] -> m [a]
unPersistHAEvents = fmap catMaybes . traverse unPersistHAEvent
