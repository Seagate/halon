-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-#  LANGUAGE CPP #-}
{-#  LANGUAGE FlexibleContexts #-}
{-#  LANGUAGE TemplateHaskell #-}
module HA.NodeAgent.Tests ( tests ) where

import HA.Resources (serviceProcess)
import HA.NodeAgent (nodeAgent,updateEQNodes, Result(..))
import HA.Network.Address ( Network, getNetworkTransport )
import HA.EventQueue ( eventQueue, EventQueue )
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
         ( Process, spawnLocal, getSelfPid, liftIO,  catch
         , getSelfNode, say, ProcessId, receiveWait
         )
#ifndef USE_MOCK_REPLICATOR
import Control.Distributed.Process ( spawn )
import Control.Distributed.Static ( closureApply )
#endif
import Control.Distributed.Process.Closure ( mkStatic, mkClosure, remotable )
import Control.Distributed.Process.Node ( LocalNode, localNodeId, newLocalNode, closeLocalNode )
import Control.Distributed.Process.Internal.Primitives ( unClosure )
import Control.Distributed.Process.Platform.Test ( tryRunProcess )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Data.List (find)
import Control.Concurrent ( throwTo, myThreadId, threadDelay )
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,MVar)
import Control.Monad ( replicateM, forM_ )
import Control.Exception ( SomeException )
import System.IO.Unsafe ( unsafePerformIO )
import Test.Framework

type RG = MC_RG EventQueue

dummyRC :: () -> Process RG -> Process ()
dummyRC () pRGroup = pRGroup >>= dummyRC'

dummyRC' :: RG -> Process ()
dummyRC' rGroup =
  flip catch (\e -> say $ show (e :: SomeException)) $ do
      self <- getSelfPid
      _ <- spawnLocal (eventQueue rGroup self)

      let loop =
           receiveWait
           [
             matchHAEvent (\(HAEvent _ str) ->
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

naTest :: Network -> ([LocalNode] -> Process ()) -> IO ()
naTest network action = withTmpDirectory $ do
  nodes <- replicateM 3 newNode
  let nids = map localNodeId nodes
  mapM_ (initialize nids) nodes

  mdone <- newEmptyMVar
  tryRunProcess (head nodes) $ do
    liftIO $ putStrLn "Testing NodeAgent..."
    nid <- getSelfNode
    cRGroup <- newRGroup $(mkStatic 'eqSDict) nids []
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
      na <- spawnLocalLink =<< unClosure (serviceProcess nodeAgent)
      Ok <- updateEQNodes na nids
      return ()

tests :: Network -> IO [TestTree]
tests network = do
    return
      [ testSuccess "rc-get-expiate" $ naTest network $ \_nodes -> do
             _ <- spawnLocal $ expiate "hello0"
             liftIO $ takeMVar sync0
             assert True

      , testSuccess "rc-get-expiate-after-eq-death" $ naTest network $ \nodes -> do
             let getNotMe = do
                     self <- getSelfNode
                     return $ find ((/=) self . localNodeId) nodes
             Just notMe <- getNotMe
             liftIO $ closeLocalNode notMe
             _ <- spawnLocal $ expiate "hello1"

             liftIO $ takeMVar sync1
             assert True
      ]
