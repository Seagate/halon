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

import HA.Multimap.Process ( startMultimap )
import HA.Multimap ( MetaInfo, StoreUpdate(..), defaultMetaInfo, updateStore
                   , getKeyValuePairs, StoreChan )
import HA.Multimap.Implementation ( fromList, Multimap )
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables ( remoteTable )

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable ( SerializableDict(..) )

import Data.ByteString.Char8 ( pack )
import Network.Transport ( Transport )
import Test.Framework

updateStoreWait :: StoreChan -> [StoreUpdate] -> Process ()
updateStoreWait mm upds = do
    (sp, rp) <- newChan
    updateStore mm upds (sendChan sp ())
    receiveChan rp

testMultimapEmpty :: StoreChan -> Process ()
testMultimapEmpty mm = do
    [] <- getKeyValuePairs mm
    updateStoreWait mm []
    [] <- getKeyValuePairs mm
    return ()

testMultimapOrder :: StoreChan -> Process ()
testMultimapOrder mm = do
    updateStoreWait mm [ InsertMany [(b0,[b1]),(b1,[b2,b3])]
                       , DeleteValues [(b1,[b3])]
                       ]
    kvs <- getKeyValuePairs mm
    assert $ fromList kvs == fromList [(b0,[b1]),(b1,[b2])]
  where
    b0:b1:b2:b3:_ = map (pack . ('b':) . show) [(0::Int)..]

testMultimapAsync :: StoreChan -> Process ()
testMultimapAsync mm = do
    (sp, rp) <- newChan
    updateStore mm [ InsertMany [(b0,[b1]),(b1,[b2,b3])] ] $ sendChan sp ()
    updateStore mm [ DeleteValues [(b1,[b3])] ] $ sendChan sp ()
    receiveChan rp
    receiveChan rp
    kvs <- getKeyValuePairs mm
    assert $ fromList kvs == fromList [(b0,[b1]),(b1,[b2])]
  where
    b0:b1:b2:b3:_ = map (pack . ('b':) . show) [(0::Int)..]

mmSDict :: SerializableDict (MetaInfo, Multimap)
mmSDict = SerializableDict

remotable [ 'mmSDict ]

tests :: Transport -> [TestTree]
tests transport =
    [ testSuccess "multimap-empty" $ setup testMultimapEmpty
    , testSuccess "multimap-order" $ setup testMultimapOrder
    , testSuccess "multimap-async" $ setup testMultimapAsync
    ]
  where
    setup action = withTmpDirectory $
      withLocalNode transport (__remoteTable remoteTable) $ \lnid -> do
        runProcess lnid $ do
          nid <- getSelfNode
          cRGroup <- newRGroup $(mkStatic 'mmSDict) "mmtest" 20 1000000 [nid]
                               (defaultMetaInfo, fromList [])
          pRGroup <- unClosure cRGroup
          rGroup <- pRGroup :: Process (MC_RG (MetaInfo, Multimap))
          self <- getSelfPid
          (mmpid, mmchan) <- startMultimap rGroup $ \loop -> link self >> loop
          link mmpid
          action mmchan
