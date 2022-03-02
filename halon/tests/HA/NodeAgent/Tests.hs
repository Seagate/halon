-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

{-#  LANGUAGE FlexibleContexts #-}
{-#  LANGUAGE TemplateHaskell #-}
{-#  LANGUAGE ExistentialQuantification #-}

module HA.NodeAgent.Tests (tests, __remoteTable) where

import HA.EventQueue
import HA.EventQueue.Process hiding (__remoteTable)
import HA.EQTracker.Process hiding (__remoteTable)
import HA.Replicator ( RGroup(..) )
import RemoteTables ( remoteTable )


import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Data.List (find)
import Data.Typeable
import Data.Functor.Identity
import Control.Concurrent ( threadDelay )
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,MVar)
import Control.Monad.Catch (catch)
import Control.Monad ( replicateM, forM_, join, void )
import Control.Exception ( SomeException )
import Control.Exception as E ( bracket )
import Network.Transport ( Transport )
import System.IO.Unsafe ( unsafePerformIO )
import Test.Helpers
import Test.Framework


dummyRC :: RGroup g => g EventQueue -> Process ()
dummyRC rGroup =
  flip catch (\e -> say $ show (e :: SomeException)) $ do
      self <- getSelfPid
      eq <- startEventQueue rGroup
      usend eq self -- Report me as the RC.

      let loop = do
           pm <- expect
           case runIdentity $ unPersistHAEvent pm of
             Just "hello0" -> liftIO $ putMVar sync0 ()
             Just "hello1" -> liftIO $ putMVar sync1 ()
             _   -> error "Unexpected event"
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

remotable [ 'eqSDict ]

naTestWithEQ :: forall g. (Typeable g, RGroup g)
             => Transport -> Proxy g -> ([LocalNode] -> Process ()) -> IO ()
naTestWithEQ transport _ action = withTmpDirectory $ E.bracket
  (replicateM 3 $ newLocalNode transport $ __remoteTable remoteTable)
  (mapM_ closeLocalNode) $ \nodes -> do
    let nids = map localNodeId nodes
    forM_ nodes $ flip runProcess $ void $ startEQTracker nids
    mdone <- newEmptyMVar
    runProcess (head nodes) $ do
      cRGroup <- newRGroup $(mkStatic 'eqSDict) "eqtest" 20 1000000 4000000 nids
                           emptyEventQueue
      forM_ nodes $ \node -> liftIO $ forkProcess node $ do
        rGroup :: g EventQueue <- join $ unClosure cRGroup
        dummyRC rGroup
      action nodes
      liftIO $ putMVar mdone ()
    takeMVar mdone
    -- Exit after transport stops being used.
    -- TODO: fix closeTransport and call it here (see ticket #211).
    -- TODO: implement closing RGroups and call it here.
    threadDelay 2000000

tests :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO [TestTree]
tests transport pg = do
    return
      [ testSuccess "rc-get-expiate" $ naTestWithEQ transport pg $ \_nodes -> do
             _ <- spawnLocal $ promulgateWait "hello0"
             liftIO $ takeMVar sync0
             assert True

      , testSuccess "rc-get-expiate-after-eq-death" $
          naTestWithEQ transport pg $ \nodes -> do
             let getNotMe = do
                     self <- getSelfNode
                     return $ find ((/=) self . localNodeId) nodes
             Just notMe <- getNotMe
             liftIO $ closeLocalNode notMe
             _ <- spawnLocal $ promulgateWait "hello1"

             liftIO $ takeMVar sync1
             assert True
      ]
