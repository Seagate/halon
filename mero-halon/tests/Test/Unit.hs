-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Unit (tests) where

import Test.Framework
import qualified HA.RecoveryCoordinator.Mero.Tests ( tests )

import HA.Network.Address (parseAddress, startNetwork)

import System.IO


-- | Temporary wrapper for components whose unit tests have not been broken up
-- into independent small tests.
monolith :: String -> IO () -> IO TestTree
monolith name = return . testSuccess name

tests :: [String] -> IO TestTree
tests argv = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    let addr0 = case argv of
            a0:_ -> a0
            _    -> error "missing ADDRESS"
        addr = maybe (error "wrong address") id $ parseAddress addr0
    network <- startNetwork addr
    monolith "RC" $ HA.RecoveryCoordinator.Mero.Tests.tests addr0 network
