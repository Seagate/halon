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
import Control.Exception ( SomeException )


eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

remotable [ 'eqSDict ]

triggerEvent :: Int -> Process ()
triggerEvent k = catch (expiate k) $ \(_ :: SomeException) -> return ()

invoke :: Serializable a => ProcessId -> a -> Process ()
invoke them x = send them x >> expect

tests :: Network -> IO [TestTree]
tests network = do
    let rt = HA.EventQueue.Tests.__remoteTable remoteTable
        transport = getNetworkTransport network
    let (==>) :: (IO () -> TestTree) -> (ProcessId -> ProcessId -> MC_RG EventQueue -> Process ()) -> TestTree
        t ==> action = t $ withTmpDirectory $ tryWithTimeout transport rt defaultTimeout $ do
            self <- getSelfPid
            let nodes = [processNodeId self]

            registerInterceptor $ \string -> case string of
                "Trim done." -> send self ()
                _ -> return ()

            cRGroup <- newRGroup $(mkStatic 'eqSDict) nodes []
            rGroup <- unClosure cRGroup >>= id
            eq <- spawnLocal (eventQueue rGroup self)
            na <- spawn (processNodeId self) (serviceProcess nodeAgent)
            Ok <- updateEQNodes na 0 nodes
            mapM_ link [eq, na]

            action eq na rGroup

    return
        [ testSuccess "eq-init-empty" ==> \_ _ rGroup -> do
              [] <- getState rGroup
              return ()
        , testSuccess "eq-one-event" ==> \_ _ rGroup -> do
              triggerEvent 1
              [ HAEvent (EventId _ 0) _ ] <- getState rGroup
              return ()
        , testSuccess "eq-many-events" ==> \_ _ rGroup -> do
              mapM_ triggerEvent [1..10]
              assert . (== 10) . length =<< getState rGroup
        , testSuccess "eq-trim-one" ==> \eq na rGroup -> do
              mapM_ triggerEvent [1..10]
              invoke eq $ EventId na 0
              assert . (== 9) . length =<< getState rGroup
        , testSuccess "eq-trim-idempotent" ==> \eq na rGroup -> do
              mapM_ triggerEvent [1..10]
              before <- map (eventCounter . eventId) <$> getState rGroup
              invoke eq $ EventId na 5
              trim1 <- map (eventCounter . eventId) <$> getState rGroup
              invoke eq $  EventId na 5
              trim2 <- map (eventCounter . eventId) <$> getState rGroup
              assert (before /= trim1 && before /= trim2 && trim1 == trim2)
        , testSuccess "eq-trim-none" ==> \eq na rGroup -> do
              mapM_ triggerEvent [1..10]
              before <- map (eventCounter . eventId) <$> getState rGroup
              invoke eq $  EventId na 11
              trim <- map (eventCounter . eventId) <$> getState rGroup
              assert (before == trim) ]
