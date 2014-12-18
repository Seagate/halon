-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
module HA.RecoveryCoordinator.Mero.Tests ( tests ) where

import Test.Framework

import HA.Resources
import HA.RecoveryCoordinator.Mero
import HA.EventQueue
import HA.EventQueue.Types
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
import qualified HA.Services.Dummy as Services ( dummy )
import qualified HA.Services.Mero as Mero ( m0d )
import qualified Mero.Messages as Mero ( StripingError(..) )
import RemoteTables ( remoteTable )

import Control.Distributed.Process
import qualified Control.Distributed.Process.Internal.Types as I
    (createMessage, messageToPayload, Process(..))
import Control.Distributed.Process.Closure ( remotableDecl, mkStatic )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Network.Transport (Transport)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ( first, second )
import Control.Concurrent.MVar
import Control.Monad (forM_)
import Control.Monad.Fix
import Data.ByteString.Char8 as B8 (ByteString)

-- XXX temp hack.
import Control.Concurrent (threadDelay)

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
runRC (eq, na, args) rGroup = do
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
   let node = Node $ processNodeId na
   -- XXX remove this threadDelay. Needed right now because service type m0d is
   -- currently hardcoded in RC, when we'd like it to start a dummy service
   -- instead when in test mode.
   liftIO $ threadDelay 1000000
   -- Encode the message the way 'expiate' does.
   send rc $ HAEvent (EventId na 0) (I.messageToPayload $ I.createMessage $
       encodeP $ ServiceFailed node Services.dummy) []
   send rc $ HAEvent (EventId na 1) (I.messageToPayload $ I.createMessage $
       Mero.StripingError node) []
   -- XXX remove this threadDelay. It's the least hassle solution for now, until
   -- we properly add event provenance.
   liftIO $ threadDelay 1000000
   send rc $ HAEvent (EventId na 2) (I.messageToPayload $ I.createMessage $
       EpochTransitionRequest na 0 1) []

mockNodeAgent :: MVar () -> Process ()
mockNodeAgent done = do
    self <- getSelfPid
    register "HA.NodeAgent" self

    receiveWait [ match $ \(caller, UpdateEQNodes _) -> send caller True ]
    say "Got UpdateEQNodes."

    "Starting service m0d" :: String <- expect
    say "Got start service."

    -- Fake being the m0d service from here onwards.
    unregister (snString . serviceName $ Mero.m0d)
    register (snString . serviceName $ Mero.m0d) self

    "Starting service dummy" :: String <- expect
    say "Got start service again following failure."

    EpochTransition{etHow = ("y = x^3" :: B8.ByteString)} <- expect
    say $ "Received epoch transition broadcast."

    EpochTransition{etHow = ("y = x^3" :: B8.ByteString)} <- expect
    say $ "Received epoch transition following request."

    liftIO $ putMVar done ()

tests :: Transport -> IO ()
tests transport =
    tryWithTimeout transport rt 5000000 $ do
        done <- liftIO $ newEmptyMVar
        na <- spawnLocal $ mockNodeAgent done
        nid <- getSelfNode

        registerInterceptor $ \string -> case string of
            str@"Starting service m0d"   -> send na str
            str@"Starting service dummy" -> send na str
            _ -> return ()

        say $ "tests node: " ++ show nid
        cRGroup <- newRGroup $(mkStatic 'testDict) [nid] ((Nothing,[]), fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        eq <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
        runRC (eq, na, IgnitionArguments [nid] [nid]) rGroup
        liftIO $ takeMVar done
  where
    rt = HA.RecoveryCoordinator.Mero.Tests.__remoteTableDecl $
         remoteTable
