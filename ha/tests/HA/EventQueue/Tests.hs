-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-#  LANGUAGE CPP #-}
{-#  LANGUAGE TemplateHaskell #-}
module HA.EventQueue.Tests ( tests ) where

import Test.Framework

import HA.Network.Address
import HA.NodeAgent
import HA.EventQueue
import HA.EventQueue.Consumer
import HA.EventQueue.Producer
import HA.EventQueue.Types
import HA.Replicator
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Serializable ( Serializable )

import Control.Applicative ((<$>))
import Control.Arrow (first)
import Control.Exception ( SomeException )


eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

setRC :: Maybe ProcessId -> EventQueue -> EventQueue
setRC = first . const

remotable [ 'eqSDict, 'setRC ]

triggerEvent :: Int -> Process ()
triggerEvent k = catch (expiate k) $ \(_ :: SomeException) -> return ()

invoke :: Serializable a => ProcessId -> a -> Process ()
invoke them x = send them x >> expect

tests :: Network -> IO [TestTree]
tests network = do
    let rt = HA.EventQueue.Tests.__remoteTable remoteTable
        transport = getNetworkTransport network
    let (==>) :: (IO () -> TestTree) -> (ProcessId -> ProcessId -> MC_RG EventQueue -> Process ()) -> TestTree
        t ==> action = t $ setup $ \eq na rGroup ->
                -- use me as the rc.
                getSelfPid >>= send eq >> action eq na rGroup

        setup :: (ProcessId -> ProcessId -> MC_RG EventQueue -> Process ()) -> IO ()
        setup action = withTmpDirectory $ tryWithTimeout transport rt defaultTimeout $ do
            self <- getSelfPid
            let nodes = [processNodeId self]

            registerInterceptor $ \string -> case string of
                "Trim done." -> send self ()
                _ -> return ()

            cRGroup <- newRGroup $(mkStatic 'eqSDict) nodes (Nothing,[])
            rGroup <- unClosure cRGroup >>= id
            eq <- spawnLocal (eventQueue rGroup)
            na <- spawn (processNodeId self) (serviceProcess nodeAgent)
            Ok <- updateEQNodes na nodes
            mapM_ link [eq, na]

            action eq na rGroup

    return
        [ testSuccess "eq-init-empty" ==> \_ _ rGroup -> do
              (_, []) <- getState rGroup
              return ()
        , testSuccess "eq-one-event" ==> \_ _ rGroup -> do
              triggerEvent 1
              (_, [ HAEvent (EventId _ 0) _ ]) <- getState rGroup
              return ()
        , testSuccess "eq-many-events" ==> \_ _ rGroup -> do
              mapM_ triggerEvent [1..10]
              assert . (== 10) . length . snd =<< getState rGroup
        , testSuccess "eq-trim-one" ==> \eq na rGroup -> do
              mapM_ triggerEvent [1..10]
              invoke eq $ EventId na 0
              assert . (== 9) . length . snd =<< getState rGroup
        , testSuccess "eq-trim-idempotent" ==> \eq na rGroup -> do
              mapM_ triggerEvent [1..10]
              before <- map (eventCounter . eventId) . snd <$> getState rGroup
              invoke eq $ EventId na 5
              trim1 <- map (eventCounter . eventId) . snd <$> getState rGroup
              invoke eq $  EventId na 5
              trim2 <- map (eventCounter . eventId) . snd <$> getState rGroup
              assert (before /= trim1 && before /= trim2 && trim1 == trim2)
        , testSuccess "eq-trim-none" ==> \eq na rGroup -> do
              mapM_ triggerEvent [1..10]
              before <- map (eventCounter . eventId) . snd <$> getState rGroup
              invoke eq $  EventId na 11
              trim <- map (eventCounter . eventId) . snd <$> getState rGroup
              assert (before == trim)
        , testSuccess "eq-with-no-rc-should-replicate" $ setup $ \_ _ rGroup -> do
              triggerEvent 1
              (_, [ HAEvent (EventId _ 0) _ ]) <- getState rGroup
              return ()
        , testSuccess "eq-should-lookup-for-rc" $ setup $ \_ _ rGroup -> do
              self <- getSelfPid
              updateStateWith rGroup $ $(mkClosure 'setRC) $ Just self
              triggerEvent 1
              (_, [ HAEvent (EventId _ 0) _ ]) <- getState rGroup
              return ()
        , testSuccess "eq-should-record-that-rc-died" $ setup $ \eq _ _ -> do
              self <- getSelfPid
              registerInterceptor $ \string -> case string of
                "RC died." -> send self ()
                _ -> return ()
              rc <- spawnLocal $ return ()
              send eq rc
              -- Wait for confirmation of RC death.
              expect
        ]
