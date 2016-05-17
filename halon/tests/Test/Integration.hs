-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Test.Integration (tests) where

import qualified HA.EventQueue.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.Multimap.Tests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests (tests, disconnectionTests)
import           HA.Replicator.Log
import qualified HA.ResourceGraph.Tests (tests)
import qualified HA.Autoboot.Tests (tests)
import Test.Transport

import Test.Tasty (TestTree, testGroup, localOption, mkTimeout)

import Data.Proxy
import Prelude

tests :: AbstractTransport -> IO TestTree
tests transport = do
    let pg = Proxy :: Proxy RLogGroup
    fmap (localOption (mkTimeout (7*60*1000000))) $
      testGroup "halon" . (:[]) . testGroup "it" <$> sequence
      [
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport pg
      , return $ testGroup "MM-process-tests" $
          HA.Multimap.ProcessTests.tests (getTransport transport) pg
      , testGroup "MM-pure" <$> return
        HA.Multimap.Tests.tests
      , testGroup "RG" <$>
          HA.ResourceGraph.Tests.tests (getTransport transport) pg
      , testGroup "RS" <$>
          ((++) <$> HA.RecoverySupervisor.Tests.tests transport pg
                <*> HA.RecoverySupervisor.Tests.disconnectionTests transport pg
          )
      , testGroup "NA" <$> HA.NodeAgent.Tests.tests (getTransport transport) pg
      , testGroup "AB" <$> HA.Autoboot.Tests.tests transport
      ]
