-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Test.Integration (tests) where

import           Prelude hiding ((<$>))
import qualified HA.EventQueue.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.Multimap.Tests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests (tests)
import qualified HA.ResourceGraph.Tests (tests)

import Test.Tasty (TestTree, testGroup)

import Control.Applicative ((<$>))
import Test.Transport

tests :: AbstractTransport -> IO TestTree
tests transport = do
    testGroup "it" <$> sequence
      [
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport
      , testGroup "MM-process-tests" <$> return
        [ HA.Multimap.ProcessTests.tests (getTransport transport) ]
      , testGroup "MM-pure" <$> return
        HA.Multimap.Tests.tests
      , testGroup "RG" <$> HA.ResourceGraph.Tests.tests (getTransport transport)
      , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests False transport
        -- Next test is commented since it doesn't pass reliably.
        -- TODO: fix liveness of paxos.
--    , HA.RecoverySupervisor.Tests.tests transport False
      , testGroup "NA" <$> HA.NodeAgent.Tests.tests (getTransport transport)
      ]
