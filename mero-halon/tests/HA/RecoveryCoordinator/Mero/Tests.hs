-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
module HA.RecoveryCoordinator.Mero.Tests
  ( testServiceRestarting
  , testEpochTransition
  ) where

import Test.Framework

import HA.Resources
import HA.RecoveryCoordinator.Mero
import HA.EventQueue
import HA.EventQueue.Producer (promulgateEQ)
import HA.Multimap.Implementation
import HA.Multimap.Process
import HA.Replicator
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import HA.NodeAgent
import HA.Service
  ( ServiceFailed(..)
  , encodeP
  , snString
  )
import qualified HA.Services.Mero as Mero ( m0d )
import qualified Mero.Messages as Mero ( StripingError(..) )
import RemoteTables ( remoteTable )

import Control.Distributed.Process
import qualified Control.Distributed.Process.Internal.Types as I
    (Process(..))
import Control.Distributed.Process.Closure ( remotableDecl, mkStatic )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Network.Transport (Transport)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ( first, second )
import Control.Monad (forM_)
import Control.Monad.Fix
import Data.ByteString.Char8 as B8 (ByteString)

instance MonadFix Process where
    mfix f = I.Process $ mfix (I.unProcess . f)

type TestReplicatedState = (EventQueue, Multimap)

remotableDecl [ [d|
  eqView :: RStateView TestReplicatedState EventQueue
  eqView = RStateView fst first

  multimapView :: RStateView TestReplicatedState Multimap
  multimapView = RStateView snd second

  testDict :: SerializableDict TestReplicatedState
  testDict = SerializableDict
  |]]

runRC :: (ProcessId, ProcessId, IgnitionArguments) -> MC_RG TestReplicatedState
         -> Process ()
runRC (eq, _, args) rGroup = do
  rec (mm, rc) <- (,)
                  <$> (spawnLocal $ do
                        () <- expect
                        link rc
                        multimap (viewRState $(mkStatic 'multimapView) rGroup))
                  <*> (spawnLocal $ do
                        () <- expect
                        recoveryCoordinator eq mm args)
  send eq rc
  forM_ [mm, rc] $ \them -> send them ()

mockNodeAgent :: Process ()
mockNodeAgent = do
    self <- getSelfPid
    register "HA.NodeAgent" self

    receiveWait [ match $ \(caller, UpdateEQNodes _) -> send caller True ]
    say "Got UpdateEQNodes."

-- | Test that the RC responds correctly to 'StripingError' and
--   'EpochTransitionRequest' messages by emitting an 'EpochTransmission'
--   to all m0d instances.
testEpochTransition :: Transport -> IO ()
testEpochTransition transport =
    tryWithTimeout transport rt 5000000 $ do
        na <- spawnLocal $ mockNodeAgent
        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"Starting service m0d"   -> send self str
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        runRC (eq, na, IgnitionArguments [nid] [nid]) rGroup

        "Starting service m0d" :: String <- expect
        say $ "m0d service started successfully."

        -- Now we pretend that we are the m0d instance. Because of the fake
        -- node agent, the real m0d never actually registers itself, hence we
        -- don't need to unregister.
        register (snString . serviceName $ Mero.m0d) self

        _ <- promulgateEQ [nid] $ Mero.StripingError (Node nid)
        EpochTransition{etHow = ("y = x^3" :: B8.ByteString)} <- expect
        say $ "Received epoch transition broadcast as a result of striping error."

        _ <- promulgateEQ [nid] $ EpochTransitionRequest self 0 1
        EpochTransition{etHow = ("y = x^3" :: B8.ByteString)} <- expect
        say $ "Received epoch transition following request."

  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable

-- | Test that the recovery co-ordinator can successfully restart a service
--   upon notification of failure.
--   This test does not verify the appropriate detection of service failure,
--   nor does it verify that the 'one service instance per node' constraint
--   is not violated.
testServiceRestarting :: Transport -> IO ()
testServiceRestarting transport = do
  tryWithTimeout transport rt 5000000 $ do
        na <- spawnLocal mockNodeAgent

        nid <- getSelfNode
        self <- getSelfPid

        registerInterceptor $ \string -> case string of
            str@"Starting service m0d"   -> send self str
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        runRC (eq, na, IgnitionArguments [nid] [nid]) rGroup

        "Starting service m0d" :: String <- expect
        say $ "m0d service started successfully."

        _ <- promulgateEQ [nid] . encodeP $ ServiceFailed (Node nid) Mero.m0d

        "Starting service m0d" :: String <- expect
        say $ "m0d service restarted successfully."
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
