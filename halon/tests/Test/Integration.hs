-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Integration (tests) where

import           Prelude hiding ((<$>))
import qualified HA.EventQueue.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests (tests)
import qualified HA.ResourceGraph.Tests (tests)

import Test.Tasty (TestTree, testGroup)

import Control.Applicative ((<$>))
import Network.Transport
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
    testGroup "it" <$> sequence
      [
#ifdef USE_RPC
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport
#else
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport internals
#endif
      , testGroup "MM-process-tests" <$> return
        [ HA.Multimap.ProcessTests.tests transport ]
      , testGroup "RG" <$> HA.ResourceGraph.Tests.tests transport
      , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests False transport
        -- Next test is commented since it doesn't pass reliably.
        -- TODO: fix liveness of paxos.
--    , HA.RecoverySupervisor.Tests.tests transport False
      , testGroup "NA" <$> HA.NodeAgent.Tests.tests transport
      ]
