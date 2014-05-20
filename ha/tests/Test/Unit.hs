-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Unit (tests) where

import Test.Framework
import qualified HA.EventQueue.Tests (tests)
import qualified HA.Network.Tests ( tests )
import qualified HA.Multimap.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.RecoverySupervisor.Tests ( tests )
import qualified HA.ResourceGraph.Tests ( tests )

import HA.Network.Address (parseAddress, startNetwork)

import Control.Applicative ((<$>))
import System.IO

tests :: [String] -> IO TestTree
tests argv = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    let addr0 = case argv of
            a0:_ -> a0
            _    -> error "missing ADDRESS"
        addr = maybe (error "wrong address") id $ parseAddress addr0
    network <- startNetwork addr
    fmap (testGroup "ut") $ sequence
        [
          testGroup "NT" <$> HA.Network.Tests.tests addr network
        , testGroup "EQ" <$> HA.EventQueue.Tests.tests network
        , testGroup "MM" <$> return
            [ testGroup "pure" HA.Multimap.Tests.tests
            , testGroup "process"
              [ HA.Multimap.ProcessTests.tests network ]
            ]
        , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests True network
        , testGroup "RG" <$> HA.ResourceGraph.Tests.tests network
        ]
