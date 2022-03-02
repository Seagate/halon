-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE CPP #-}

module Main where

import qualified Control.SpineSeq.Tests (tests)
import qualified HA.Autoboot.Tests (tests)
import qualified HA.EventQueue.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.Multimap.Tests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests (tests, disconnectionTests)
import           HA.Replicator.Log
import           HA.Replicator.Mock
import qualified HA.ResourceGraph.Tests (tests)
import qualified HA.Storage.Tests (tests)
import Test.Run (runTests)
import Test.Transport

import Test.Tasty (TestTree, testGroup, localOption, mkTimeout)

import Data.Proxy
import System.IO


main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  runTests tests

tests :: AbstractTransport -> IO TestTree
tests transport = do
    utests <- unitTests transport
    itests <- integrationTests transport
    return $ testGroup "halon" [utests, itests]

unitTests :: AbstractTransport -> IO TestTree
unitTests transport = do
    let pg = Proxy :: Proxy RLocalGroup
    testGroup "ut" <$> sequence
        [
          testGroup "EQ" <$> HA.EventQueue.Tests.tests transport pg
        , testGroup "MM" <$> return
            [ testGroup "pure" HA.Multimap.Tests.tests
            , testGroup "process" $
                HA.Multimap.ProcessTests.tests (getTransport transport) pg
            ]
        , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests transport pg
        , testGroup "RG" <$>
            HA.ResourceGraph.Tests.tests (getTransport transport) pg
        , testGroup "NA" <$>
            HA.NodeAgent.Tests.tests (getTransport transport) pg
        , pure Control.SpineSeq.Tests.tests
        , HA.Storage.Tests.tests (getTransport transport)
        ]

integrationTests :: AbstractTransport -> IO TestTree
integrationTests transport = do
    let pg = Proxy :: Proxy RLogGroup
    fmap (localOption (mkTimeout (7*60*1000000))) $
      testGroup "it" <$> sequence
      [
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport pg
      , return $ testGroup "MM-process" $
          HA.Multimap.ProcessTests.tests (getTransport transport) pg
      , testGroup "RG" <$>
          HA.ResourceGraph.Tests.tests (getTransport transport) pg
      , testGroup "RS" <$>
          ((++) <$> HA.RecoverySupervisor.Tests.tests transport pg
                <*> HA.RecoverySupervisor.Tests.disconnectionTests transport pg
          )
      , testGroup "NA" <$> HA.NodeAgent.Tests.tests (getTransport transport) pg
      , testGroup "AB" <$> HA.Autoboot.Tests.tests transport
      ]
