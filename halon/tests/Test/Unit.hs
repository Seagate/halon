-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Unit (tests) where

import qualified HA.EventQueue.Tests (tests)
import qualified HA.Multimap.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests ( tests )
import qualified HA.ResourceGraph.Tests ( tests )

import Test.Tasty (TestTree, testGroup)

import Control.Applicative ((<$>))
import Network.Transport (Transport)
#ifndef USE_RPC
import qualified Network.Transport.TCP as TCP
#endif

#ifdef USE_RPC
tests :: Transport -> IO TestTree
tests transport = do
#else
tests :: Transport -> TCP.TransportInternals -> IO TestTree
tests transport internals = do
#endif
    fmap (testGroup "ut") $ sequence
        [
#ifdef USE_RPC
          testGroup "EQ" <$> HA.EventQueue.Tests.tests transport
#else
          testGroup "EQ" <$> HA.EventQueue.Tests.tests transport internals
#endif
        , testGroup "MM" <$> return
            [ testGroup "pure" HA.Multimap.Tests.tests
            , testGroup "process"
              [ HA.Multimap.ProcessTests.tests transport ]
            ]
        , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests True transport
        , testGroup "RG" <$> HA.ResourceGraph.Tests.tests transport
        , testGroup "NA" <$> HA.NodeAgent.Tests.tests transport
        ]
