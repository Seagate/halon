-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-#  LANGUAGE CPP #-}
{-#  LANGUAGE FlexibleContexts #-}
{-#  LANGUAGE TemplateHaskell #-}

module HA.NodeAgent.Tests ( tests, dummyRC__static, dummyRC__sdict) where

import HA.EventQueue ( EventQueue, startEventQueue, emptyEventQueue )
import HA.EventQueue.Producer (expiate)
import HA.EventQueue.Types (HAEvent(..))
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import HA.EQTracker hiding (__remoteTable)
import RemoteTables ( remoteTable )


import Control.Distributed.Process
#ifndef USE_MOCK_REPLICATOR
import Control.Distributed.Static ( closureApply )
import Control.Distributed.Process.Closure ( mkClosure )
#endif
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Data.List (find)
import Control.Concurrent ( threadDelay )
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,MVar)
import Control.Monad ( replicateM, forM_, void )
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
      eq <- startEventQueue rGroup
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
naTestWithEQ transport action = withTmpDirectory $ E.bracket
  (replicateM 3 $ newLocalNode transport $ __remoteTable remoteTable)
  (mapM_ closeLocalNode) $ \nodes -> do
    let nids = map localNodeId nodes
    forM_ nodes $ flip runProcess $ void $ startEQTracker nids
    mdone <- newEmptyMVar
    runProcess (head nodes) $ do
      cRGroup <- newRGroup $(mkStatic 'eqSDict) "eqtest" 20 1000000 nids
                           emptyEventQueue
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
      ]
