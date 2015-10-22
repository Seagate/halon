-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-#  LANGUAGE CPP #-}
{-#  LANGUAGE FlexibleContexts #-}
{-#  LANGUAGE TemplateHaskell #-}

module HA.NodeAgent.Tests ( tests, dummyRC__static, dummyRC__sdict) where

import HA.EventQueue ( EventQueue, eventQueueLabel )
import HA.EventQueue.Definitions (eventQueue)
import HA.EventQueue.Producer (expiate)
import HA.EventQueue.Types (PersistMessage(..), HAEvent(..))
import HA.Process
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import HA.EQTracker
import RemoteTables ( remoteTable )


import Control.Distributed.Process
#ifndef USE_MOCK_REPLICATOR
import Control.Distributed.Static ( closureApply )
import Control.Distributed.Process.Closure ( mkClosure )
#endif
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Node ( LocalNode, localNodeId, newLocalNode, closeLocalNode )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Data.List (find, isPrefixOf, nub, (\\))
import Control.Concurrent ( threadDelay )
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,MVar)
import Control.Monad ( replicateM, forM_, forever )
import Control.Exception ( SomeException )
import Control.Exception as E ( bracket )
import Network.Transport ( Transport )
import System.IO.Unsafe ( unsafePerformIO )
import Test.Framework

type RG = MC_RG EventQueue

dummyRC :: () -> Process RG -> Process ()
dummyRC () pRGroup = pRGroup >>= dummyRC'

dummyRC' :: RG -> Process ()
dummyRC' rGroup =
  flip catch (\e -> say $ show (e :: SomeException)) $ do
      self <- getSelfPid
      eq <- spawnLocal (eventQueue rGroup)
      usend eq self -- Report me as the RC.

      let loop = do
           HAEvent _ str _ <- expect
           case str of
             "hello0" -> liftIO $ putMVar sync0 ()
             "hello1" -> liftIO $ putMVar sync1 ()
             _        -> error "Unexpected event"
           loop
      loop

{-# NOINLINE sync0 #-}
sync0 :: MVar ()
sync0 = unsafePerformIO $ newEmptyMVar

{-# NOINLINE sync1 #-}
sync1 :: MVar ()
sync1 = unsafePerformIO $ newEmptyMVar

eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

remotable [ 'eqSDict, 'dummyRC ]

naTestWithEQ :: Transport -> ([LocalNode] -> Process ()) -> IO ()
naTestWithEQ transport action = withTmpDirectory $ do
  nodes <- replicateM 3 newNode
  let nids = map localNodeId nodes
  mapM_ (initialize nids) nodes

  mdone <- newEmptyMVar
  tryRunProcess (head nodes) $ do
    cRGroup <- newRGroup $(mkStatic 'eqSDict) 20 1000000 nids (Nothing,[])
#ifdef USE_MOCK_REPLICATOR
    rGroup <- unClosure cRGroup >>= id
    forM_ nids $ const $ spawnLocal $ dummyRC' rGroup
#else
    forM_ nids $ flip spawn $ $(mkClosure 'dummyRC) ()
                               `closureApply` cRGroup
#endif
    action nodes
    liftIO $ putMVar mdone ()
  takeMVar mdone
  -- Exit after transport stops being used.
  -- TODO: fix closeTransport and call it here (see ticket #211).
  -- TODO: implement closing RGroups and call it here.
  threadDelay 2000000
  mapM_ closeLocalNode nodes
  where
    newNode = newLocalNode transport
                       $ __remoteTable remoteTable
    initialize nids node = tryRunProcess node $ do
      eqt <- startEQTracker nids
      link eqt

naTest :: Transport -> ([NodeId] -> Process ()) -> IO ()
naTest transport action = withTmpDirectory $ E.bracket
    (replicateM 2 $ newLocalNode transport
                                 (__remoteTable remoteTable))
    (mapM closeLocalNode)
    $ \nodes -> do
      let nids = map localNodeId nodes
      tryRunProcess (nodes !! 0) $ do
        self <- getSelfPid
        eq1 <- spawnLocal $ forever $
                 (expect :: Process (ProcessId, PersistMessage))
                 >>= usend self . (,) (nids !! 0)
        register eventQueueLabel eq1
        liftIO $ tryRunProcess (nodes !! 1) $ do
          eq2 <- spawnLocal $ forever $
                   (expect :: Process (ProcessId, PersistMessage))
                   >>= usend self . (,) (nids !! 1)
          register eventQueueLabel eq2
        eqt <- startEQTracker nids
        link eqt
        action nids

expectEventOnNode :: NodeId -> Process ProcessId
expectEventOnNode n = receiveWait
    [ matchIf (\(n', (_sender, PersistMessage _ _)) -> n' == n)
              (return . fst . snd)
    ]

tests :: Transport -> IO [TestTree]
tests transport = do
    return
      [ testSuccess "rc-get-expiate" $ naTestWithEQ transport $ \_nodes -> do
             _ <- spawnLocal $ expiate "hello0"
             liftIO $ takeMVar sync0
             assert True

      , testSuccess "rc-get-expiate-after-eq-death" $ naTestWithEQ transport $ \nodes -> do
             let getNotMe = do
                     self <- getSelfNode
                     return $ find ((/=) self . localNodeId) nodes
             Just notMe <- getNotMe
             liftIO $ closeLocalNode notMe
             _ <- spawnLocal $ expiate "hello1"

             liftIO $ takeMVar sync1
             assert True

      , testSuccess "na-should-compress-path" $ naTest transport $ \nids -> do
            self <- getSelfPid
            registerInterceptor $ \string ->
              if "Got PreferReplicas:" `isPrefixOf` string
              then usend self ()
              else return ()

            -- We get an event on both nodes.
            _ <- spawnLocal $ expiate "hello1"
            sender0 <- expectEventOnNode $ nids !! 0
            _ <- expectEventOnNode $ nids !! 1
            usend sender0 (nids !! 0, nids !! 0)
            () <- expect

            -- We still get an event on the first node and suggest NA to use the
            -- second node.
            _ <- spawnLocal $ expiate "hello2"
            sender1 <- expectEventOnNode $ nids !! 0
            usend sender1 (nids !! 0, nids !! 1)
            () <- expect

            -- We get an event on the second node.
            _ <- spawnLocal $ expiate "hello3"
            sender2 <- expectEventOnNode $ nids !! 1
            usend sender2 (nids !! 1, nids !! 1)

            -- We get the next event on the second node again.
            _ <- spawnLocal $ expiate "hello4"
            sender3 <- expectEventOnNode $ nids !! 1
            usend sender3 (nids !! 1, nids !! 1)

      , testSuccess "na-should-compress-path-with-failures" $ naTest transport $ \nids -> do

            self <- getSelfPid
            registerInterceptor $ \string ->
              if "Got PreferReplicas:" `isPrefixOf` string
              then usend self ()
              else return ()

            -- We get an event on both nodes.
            _ <- spawnLocal $ expiate "hello1"
            sender0 <- expectEventOnNode $ nids !! 0
            _ <- expectEventOnNode $ nids !! 1
            usend sender0 (nids !! 0, nids !! 0)
            () <- expect

            -- We still get an event on the first node and suggest NA to use the
            -- second node.
            _ <- spawnLocal $ expiate "hello2"
            sender1 <- expectEventOnNode $ nids !! 0
            usend sender1 (nids !! 0, nids !! 1)
            () <- expect

            -- We get an event on the second node, but we are not going to
            -- reply, so NA should resend to the first node.
            _ <- spawnLocal $ expiate "hello3"
            _ <- expectEventOnNode $ nids !! 1

            sender2 <- expectEventOnNode $ nids !! 0
            usend sender2 (nids !! 0, nids !! 1)
            () <- expect

            -- We get an event on the second node and we reply. But because we
            -- didn't reply last time, NA will also send the event to the last
            -- responsive node, that is the first one.
            _ <- spawnLocal $ expiate "hello4"
            evpairs <- replicateM 2 $ (expect :: Process (NodeId, (ProcessId, PersistMessage)))
            let nids4 = nub $ map fst evpairs
                evs   = nub $ map snd evpairs
                (_, (sender, PersistMessage _ _)) = head evpairs
            -- The same event was sent multiple times.
            True <- return $ length evs == 1
            -- The event was sent to both nodes.
            True <- return $ length nids4 == 2
            True <- return $ null $ nids4 \\ nids
            usend sender (nids !! 1, nids !! 1)
            () <- expect

            -- We get the next event on the second node again, and we suggest
            -- the first node.
            _ <- spawnLocal $ expiate "hello5"
            sender3 <- expectEventOnNode $ nids !! 1
            usend sender3 (nids !! 1, nids !! 0)
            () <- expect

            -- We get the next event on the first node.
            _ <- spawnLocal $ expiate "hello6"
            sender4 <- expectEventOnNode $ nids !! 0
            usend sender4 (nids !! 0, nids !! 0)
            () <- expect

            -- We get the next event on the first node again.
            _ <- spawnLocal $ expiate "hello7"
            sender5 <- expectEventOnNode $ nids !! 0
            usend sender5 (nids !! 0, nids !! 0)
      ]
