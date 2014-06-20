-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Integration (tests) where

import Test.Framework
import HA.Network.Address ( startNetwork, parseAddress )
import qualified HA.EventQueue.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests ( tests )
import qualified HA.ResourceGraph.Tests ( tests )

import Control.Applicative ( (<$>) )
import System.Environment (lookupEnv)
import System.IO ( hSetBuffering, BufferMode(..), stdout, stderr )

tests :: [String] -> IO TestTree
tests argv = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    addr0 <- case argv of
            a0:_ -> return a0
            _    ->
#if USE_RPC
                    maybe (error "TEST_LISTEN environment variable is not set") id <$> lookupEnv "TEST_LISTEN"
#else
                    maybe "localhost:0" id <$> lookupEnv "TEST_LISTEN"
#endif
    let addr = maybe (error "wrong address") id $ parseAddress addr0
    network <- startNetwork addr
    testGroup "it" <$> sequence
      [ testGroup "EQ" <$> HA.EventQueue.Tests.tests network
      , testGroup "MM-process-tests" <$> return
        [ HA.Multimap.ProcessTests.tests network ]
      , testGroup "RG" <$> HA.ResourceGraph.Tests.tests network
      , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests False network
        -- Next test is commented since it doesn't pass reliably.
        -- TODO: fix liveness of paxos.
--    , HA.RecoverySupervisor.Tests.tests network False
      , testGroup "NA" <$> HA.NodeAgent.Tests.tests network
      ]
