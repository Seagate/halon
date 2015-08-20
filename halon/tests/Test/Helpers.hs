-- |
-- Module: Test.Helpers
-- Copyright : (C) 2015 Seagate Technology Limited.
--
module Test.Helpers where

import HA.EventQueue.Types
import Data.Maybe (catMaybes)
import Control.Distributed.Process
import Control.Distributed.Process.Serializable

import qualified Test.Tasty.HUnit as HU

assertBool :: String -> Bool -> Process ()
assertBool s b = liftIO $ HU.assertBool s b

assertEqual :: (Eq a, Show a) => String -> a -> a -> Process ()
assertEqual s a b = liftIO $ HU.assertEqual s a b


unPersistHAEvent :: (Monad m, Serializable a) => PersistMessage -> m (Maybe a)
unPersistHAEvent (PersistMessage _ m) = fmap eventPayload <$> unwrapMessage m

unPersistHAEvents :: (Serializable a,Monad m) => [PersistMessage] -> m [a]
unPersistHAEvents = fmap catMaybes . traverse unPersistHAEvent

