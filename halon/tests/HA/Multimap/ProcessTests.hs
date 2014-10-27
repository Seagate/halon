-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module HA.Multimap.ProcessTests where

import HA.Multimap.Process ( multimap )
import HA.Multimap ( StoreUpdate(..), updateStore, getKeyValuePairs )
import HA.Multimap.Implementation ( fromList, Multimap )
import HA.Process
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables ( remoteTable )

import Control.Distributed.Process
  ( Process
  , spawnLocal
  , getSelfPid
  , liftIO
  , link
  , getSelfNode
  , catch
  , unClosure
  )
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Node ( newLocalNode, closeLocalNode )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Control.Concurrent ( MVar, newEmptyMVar, putMVar, takeMVar, threadDelay )
import Control.Exception ( SomeException )
import Data.ByteString.Char8 ( pack )
import Network.Transport ( Transport )
import System.IO.Unsafe ( unsafePerformIO )
import Test.Framework

testMultimap :: MC_RG Multimap -> Process ()
testMultimap rGroup =
  flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
      mm <- spawnLocalAndLink (multimap rGroup)
      Just [] <- getKeyValuePairs mm
      Just () <- updateStore mm []
      Just [] <- getKeyValuePairs mm
      Just () <- updateStore mm [ InsertMany [(b0,[b1]),(b1,[b2,b3])]
                                , DeleteValues [(b1,[b3])]
                                ]
      Just kvs <- getKeyValuePairs mm
      assert $ fromList kvs == fromList [(b0,[b1]),(b1,[b2])]
      liftIO $ putMVar mdone ()

  where

    spawnLocalAndLink p = getSelfPid >>= spawnLocal . (>>p) . link

    b0:b1:b2:b3:_ = map (pack . ('b':) . show) [(0::Int)..]

{-# NOINLINE mdone #-}
mdone :: MVar ()
mdone = unsafePerformIO $ newEmptyMVar

mmSDict :: SerializableDict Multimap
mmSDict = SerializableDict

remotable [ 'mmSDict ]

tests :: Transport -> TestTree
tests transport = testSuccess "multimap" . withTmpDirectory $ do
    lnid <- newLocalNode transport
            $ __remoteTable remoteTable
    tryRunProcess lnid $ do
        nid <- getSelfNode
        cRGroup <- newRGroup $(mkStatic 'mmSDict) [nid] (fromList [])
        pRGroup <- unClosure cRGroup
        rGroup <- pRGroup
        testMultimap rGroup
    takeMVar mdone
    -- Exit after transport stops being used.
    -- TODO: fix closeTransport and call it here (see ticket #211).
    -- TODO: implement closing RGroups and call it here.
    threadDelay 2000000
    closeLocalNode lnid
