-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Test.Integration (tests) where

import qualified HA.EventQueue.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.Multimap.Tests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests (tests)
import qualified HA.ResourceGraph.Tests (tests)
import qualified HA.Autoboot.Tests (tests)

import Test.Tasty (TestTree, testGroup, localOption, mkTimeout)

import Test.Transport
import Prelude

tests :: AbstractTransport -> IO TestTree
tests transport = fmap (localOption (mkTimeout (7*60*1000000))) $
    testGroup "it" <$> sequence
      [
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport
      , testGroup "MM-process-tests" <$> return
        [ HA.Multimap.ProcessTests.tests (getTransport transport) ]
      , testGroup "MM-pure" <$> return
        HA.Multimap.Tests.tests
      , testGroup "RG" <$> HA.ResourceGraph.Tests.tests (getTransport transport)
      , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests transport
      , testGroup "NA" <$> HA.NodeAgent.Tests.tests (getTransport transport)
      , testGroup "AB" <$> HA.Autoboot.Tests.tests transport
      ]
