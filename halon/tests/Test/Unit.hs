-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Test.Unit (tests) where

import Prelude hiding ((<$>))
import qualified HA.EventQueue.Tests (tests)
import qualified HA.Multimap.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests ( tests )
import qualified HA.ResourceGraph.Tests ( tests )
import qualified Control.SpineSeq.Tests ( tests )

import Test.Tasty (TestTree, testGroup)

import Control.Applicative ((<$>))
import Test.Transport

tests :: AbstractTransport -> IO TestTree
tests transport = do
    fmap (testGroup "ut") $ sequence
        [
          testGroup "EQ" <$> HA.EventQueue.Tests.tests transport
        , testGroup "MM" <$> return
            [ testGroup "pure" HA.Multimap.Tests.tests
            , testGroup "process"
              [ HA.Multimap.ProcessTests.tests (getTransport transport) ]
            ]
        , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests True transport
        , testGroup "RG" <$> HA.ResourceGraph.Tests.tests (getTransport transport)
        , testGroup "NA" <$> HA.NodeAgent.Tests.tests (getTransport transport)
        , pure Control.SpineSeq.Tests.tests
        ]
