-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Unit test for checking cluster properties.
{-# LANGUAGE TemplateHaskell #-}
module HA.Test.Cluster where

import HA.EventQueue.Producer (promulgateEQ)
import HA.NodeUp ( nodeUp )
import HA.Resources
import HA.RecoveryCoordinator.Definitions
import HA.Startup
import HA.Service
  ( ServiceStart(..)
  , ServiceStartRequest(..)
  , ServiceStopRequest(..)
  , encodeP
  )
import qualified HA.Services.DecisionLog as DLog
import Test.Framework

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Static ( closureCompose )
import Network.Transport
import Data.List

import Test.Tasty.HUnit
import TestRunner
import RemoteTables

tests :: Transport -> TestTree
tests transport = testGroup "Cluster"
  [ testCase "service-stop" $ testServiceStop transport ]


testServiceStop :: Transport -> Assertion
testServiceStop transport = runTest 2 10 1000000 transport remoteTable $ \[n] -> do
  self <- getSelfPid
  -- Startup halon
  let rcClosure = $(mkStaticClosure 'recoveryCoordinator)
        `closureCompose` $(mkStaticClosure 'ignitionArguments)
  _ <- liftIO $ forkProcess n $ do
        startupHalonNode rcClosure
        usend self ()
  () <- expect

  let args = ( False :: Bool
             , [localNodeId n]
             , 1000 :: Int
             , 1000000 :: Int
             , $(mkClosure 'recoveryCoordinator) $ ignitionArguments [localNodeId n]
             , 3*1000000 :: Int
             )
  _  <- liftIO $ forkProcess n $ ignition args >> usend self ()
  () <- expect
  _  <- liftIO $ forkProcess n $ do
          nodeUp ([localNodeId n], 1000000)
          usend self ()
  () <- expect
  _  <- liftIO $ forkProcess n $ registerInterceptor $ \string -> do
          case string of
            str' | "started decision-log service" `isInfixOf` str' -> usend self "Test 1"
            _ -> return ()

  _ <- promulgateEQ [localNodeId n] . encodeP $
         ServiceStartRequest Start (Node $ localNodeId n) DLog.decisionLog
          (DLog.processOutput self) []
  "Test 1" :: String <- expect
  _ <- promulgateEQ [localNodeId n] . encodeP $
         ServiceStopRequest (Node $ localNodeId n) DLog.decisionLog

  mt <- receiveTimeout 1000000
    [ matchIf (\s -> "Test 1" `isInfixOf` s) (\_ -> return ())
    ]
  case mt of
    Nothing -> return ()
    Just () -> liftIO $ assertFailure "service should not be restarted."