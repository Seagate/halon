-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-#  LANGUAGE CPP #-}
{-#  LANGUAGE FlexibleContexts #-}
{-#  LANGUAGE TemplateHaskell #-}

module HA.NodeAgent.Tests ( tests ) where

import HA.Service (serviceProcess)
import HA.NodeAgent
  ( NodeAgentConf(..)
  , nodeAgent
  , updateEQNodes
  )
import HA.Network.Address ( Network, getNetworkTransport )
import HA.Process
import HA.EventQueue ( eventQueue, EventQueue, eventQueueLabel )
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables ( remoteTable )
import HA.EventQueue.Producer (expiate)
import HA.EventQueue.Consumer (HAEvent(..),matchHAEvent)

import Control.Distributed.Process
  ( Process
  , spawnLocal
  , getSelfPid
  , liftIO
  , catch
  , send
  , expect
  , getSelfNode
  , say
  , ProcessId
  , receiveWait
  , NodeId
  , register
  )
#ifndef USE_MOCK_REPLICATOR
import Control.Distributed.Process ( spawn )
import Control.Distributed.Static ( closureApply )
import Control.Distributed.Process.Closure ( mkClosure )
#endif
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Node ( LocalNode, localNodeId, newLocalNode, closeLocalNode )
import Control.Distributed.Process.Internal.Primitives ( unClosure )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Data.Defaultable
import Data.List (find, nub, (\\))
import Control.Concurrent ( throwTo, myThreadId, threadDelay )
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,MVar)
import Control.Monad ( replicateM, forM_, forever )
import Control.Exception ( SomeException, bracket )
import Data.ByteString ( ByteString )
import System.IO.Unsafe ( unsafePerformIO )
import Test.Framework

type RG = MC_RG EventQueue

testConf :: NodeAgentConf
testConf = NodeAgentConf {
    softTimeout = Configured 5000000
  , timeout = Configured 10000000
}

dummyRC :: () -> Process RG -> Process ()
dummyRC () pRGroup = pRGroup >>= dummyRC'

dummyRC' :: RG -> Process ()
dummyRC' rGroup =
  flip catch (\e -> say $ show (e :: SomeException)) $ do
      self <- getSelfPid
      eq <- spawnLocal (eventQueue rGroup)
      send eq self -- Report me as the RC.

      let loop =
           receiveWait
           [
             matchHAEvent (\(HAEvent _ str _) ->
                case str of
                  "hello0" -> liftIO $ putMVar sync0 ()
                  "hello1" -> liftIO $ putMVar sync1 ()
                  _ -> error "Unexpected event"
             )
           ] >> loop

      _ <- loop
      return ()

{- NOINLINE sync0 #-}
sync0 :: MVar ()
sync0 = unsafePerformIO $ newEmptyMVar

{- NOINLINE sync1 #-}
sync1 :: MVar ()
sync1 = unsafePerformIO $ newEmptyMVar

eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

remotable [ 'eqSDict, 'dummyRC ]

spawnLocalLink :: Process () -> Process ProcessId
spawnLocalLink f =
  do self <- liftIO myThreadId
     spawnLocal $ flip catch (\e -> liftIO $ throwTo self (e :: SomeException)) $ f

naTestWithEQ :: Network -> ([LocalNode] -> Process ()) -> IO ()
naTestWithEQ network action = withTmpDirectory $ do
  nodes <- replicateM 3 newNode
  let nids = map localNodeId nodes
  mapM_ (initialize nids) nodes

  mdone <- newEmptyMVar
  tryRunProcess (head nodes) $ do
    liftIO $ putStrLn "Testing NodeAgent..."
    nid <- getSelfNode
    cRGroup <- newRGroup $(mkStatic 'eqSDict) nids (Nothing,[])
    rGroup <- unClosure cRGroup >>= id
#ifdef USE_MOCK_REPLICATOR
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
    newNode = newLocalNode (getNetworkTransport network)
                       $ __remoteTable remoteTable
    initialize nids node = tryRunProcess node $ do
      na <- spawnLocalLink . ($ testConf) =<< unClosure (serviceProcess nodeAgent)
      True <- updateEQNodes na nids
      return ()

naTest :: Network -> ([NodeId] -> Process ()) -> IO ()
naTest network action = withTmpDirectory $ bracket
    (replicateM 2 $ newLocalNode (getNetworkTransport network)
                                 (__remoteTable remoteTable))
    (mapM closeLocalNode)
    $ \nodes -> do
      let nids = map localNodeId nodes
      tryRunProcess (nodes !! 0) $ do
        self <- getSelfPid
        eq1 <- spawnLocal $ forever $
                 (expect :: Process (ProcessId, HAEvent [ByteString]))
                 >>= send self . (,) (nids !! 0)
        register eventQueueLabel eq1
        liftIO $ tryRunProcess (nodes !! 1) $ do
          eq2 <- spawnLocal $ forever $
                   (expect :: Process (ProcessId, HAEvent [ByteString]))
                   >>= send self . (,) (nids !! 1)
          register eventQueueLabel eq2
        na <- spawnLocalLink =<< (fmap (\p -> p testConf)
                                  $ unClosure (serviceProcess nodeAgent))
        True <- updateEQNodes na nids
        action nids

expectEventOnNode :: NodeId -> Process ProcessId
expectEventOnNode n = do
    (n', (sender, HAEvent _ _ _)) <- expect :: Process (NodeId, (ProcessId, HAEvent [ByteString]))
    True <- return $ n == n'
    return sender

tests :: Network -> IO [TestTree]
tests network = do
    return
      [ testSuccess "rc-get-expiate" $ naTestWithEQ network $ \_nodes -> do
             _ <- spawnLocal $ expiate "hello0"
             liftIO $ takeMVar sync0
             assert True

      , testSuccess "rc-get-expiate-after-eq-death" $ naTestWithEQ network $ \nodes -> do
             let getNotMe = do
                     self <- getSelfNode
                     return $ find ((/=) self . localNodeId) nodes
             Just notMe <- getNotMe
             liftIO $ closeLocalNode notMe
             _ <- spawnLocal $ expiate "hello1"

             liftIO $ takeMVar sync1
             assert True

      , testSuccess "na-should-compress-path" $ naTest network $ \nids -> do
            -- We get an event on the first node.
            _ <- spawnLocal $ expiate "hello1"
            sender0 <- expectEventOnNode $ nids !! 0
            send sender0 (nids !! 0, nids !! 0)

            -- We still get an event on the first node and suggest NA to use the
            -- second node.
            _ <- spawnLocal $ expiate "hello2"
            sender1 <- expectEventOnNode $ nids !! 0
            send sender1 (nids !! 0, nids !! 1)

            -- We get an event on the second node.
            _ <- spawnLocal $ expiate "hello3"
            sender2 <- expectEventOnNode $ nids !! 1
            send sender2 (nids !! 1, nids !! 1)

            -- We get the next event on the second node again.
            _ <- spawnLocal $ expiate "hello4"
            sender3 <- expectEventOnNode $ nids !! 1
            send sender3 (nids !! 1, nids !! 1)

      , testSuccess "na-should-compress-path-with-failures" $ naTest network $ \nids -> do
            -- We get an event on the first node.
            _ <- spawnLocal $ expiate "hello1"
            sender0 <- expectEventOnNode $ nids !! 0
            send sender0 (nids !! 0, nids !! 0)

            -- We still get an event on the first node and suggest NA to use the
            -- second node.
            _ <- spawnLocal $ expiate "hello2"
            sender1 <- expectEventOnNode $ nids !! 0
            send sender1 (nids !! 0, nids !! 1)

            -- We get an event on the second node, but we are not going to
            -- reply, so NA should resend to the first node.
            _ <- spawnLocal $ expiate "hello3"
            _ <- expectEventOnNode $ nids !! 1

            sender2 <- expectEventOnNode $ nids !! 0
            send sender2 (nids !! 0, nids !! 1)

            -- We get an event on the second node and we reply. But because we
            -- didn't reply last time, NA will also send the event to the last
            -- responsive node, that is the first one.
            _ <- spawnLocal $ expiate "hello4"
            evpairs <- replicateM 2 $ (expect :: Process (NodeId, (ProcessId, HAEvent [ByteString])))
            let nids4 = nub $ map fst evpairs
                evs   = nub $ map snd evpairs
                (_, (sender, HAEvent _ _ _)) = head evpairs
            -- The same event was sent multiple times.
            True <- return $ length evs == 1
            -- The event was sent to both nodes.
            True <- return $ length nids4 == 2
            True <- return $ null $ nids4 \\ nids
            send sender (nids !! 1, nids !! 1)

            -- We get the next event on the second node again, and we suggest
            -- the first node.
            _ <- spawnLocal $ expiate "hello5"
            sender3 <- expectEventOnNode $ nids !! 1
            send sender3 (nids !! 1, nids !! 0)

            -- We get the next event on the first node.
            _ <- spawnLocal $ expiate "hello6"
            sender4 <- expectEventOnNode $ nids !! 0
            send sender4 (nids !! 0, nids !! 0)

            -- We get the next event on the first node again.
            _ <- spawnLocal $ expiate "hello7"
            sender5 <- expectEventOnNode $ nids !! 0
            send sender5 (nids !! 0, nids !! 0)
      ]
