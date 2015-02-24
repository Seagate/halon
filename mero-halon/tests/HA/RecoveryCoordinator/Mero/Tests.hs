-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module HA.RecoveryCoordinator.Mero.Tests
  ( testServiceRestarting
  ) where

import Test.Framework

import HA.Resources
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.EventQueue
import HA.EventQueue.Producer (promulgateEQ)
import HA.Multimap.Implementation
import HA.Multimap.Process
import HA.NodeUp (nodeUp)
import HA.Replicator
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import HA.Service
  ( ServiceFailed(..)
  , ServiceStartRequest(..)
  , encodeP
  )
import qualified HA.Services.Dummy as Dummy
import RemoteTables ( remoteTable )

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( remotableDecl, mkStatic )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Network.Transport (Transport)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ( first, second )
import Control.Monad (forM_)

import Data.Defaultable

type TestReplicatedState = (EventQueue, Multimap)

remotableDecl [ [d|
  eqView :: RStateView TestReplicatedState EventQueue
  eqView = RStateView fst first

  multimapView :: RStateView TestReplicatedState Multimap
  multimapView = RStateView snd second

  testDict :: SerializableDict TestReplicatedState
  testDict = SerializableDict
  |]]

runRC :: (ProcessId, IgnitionArguments) -> MC_RG TestReplicatedState
         -> Process ()
runRC (eq, args) rGroup = do
  rec (mm, rc) <- (,)
                  <$> (spawnLocal $ do
                        () <- expect
                        link rc
                        multimap (viewRState $(mkStatic 'multimapView) rGroup))
                  <*> (spawnLocal $ do
                        () <- expect
                        recoveryCoordinator args eq mm)
  send eq rc
  forM_ [mm, rc] $ \them -> send them ()

-- | Test that the recovery co-ordinator can successfully restart a service
--   upon notification of failure.
--   This test does not verify the appropriate detection of service failure,
--   nor does it verify that the 'one service instance per node' constraint
--   is not violated.
testServiceRestarting :: Transport -> IO ()
testServiceRestarting transport = do
    withTmpDirectory $ tryWithTimeout transport rt 15000000 $ do
        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"Starting service dummy"   -> send self str
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                             [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        runRC (eq, IgnitionArguments [nid]) rGroup

        nodeUp ([nid], 2000000)
        _ <- promulgateEQ [nid] . encodeP $
          ServiceStartRequest (Node nid) Dummy.dummy
            (Dummy.DummyConf $ Configured "Test 1")

        "Starting service dummy" :: String <- expect
        say $ "dummy service started successfully."

        _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Dummy.dummy

        "Starting service dummy" :: String <- expect
        say $ "dummy service restarted successfully."
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
