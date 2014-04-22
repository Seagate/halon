-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Implements the process that manages the replicated multimap.
--

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.Multimap.Process
    ( multimap, __remoteTable ) where

import HA.Multimap ( StoreUpdate(..) )
import HA.Multimap.Implementation
            ( Multimap, insertMany, deleteValues, deleteKeys, toList )
import HA.Replicator ( RGroup, updateStateWith, getState )

import Control.Distributed.Process ( Process, catch , receiveWait )
import Control.Distributed.Process.Platform.Call ( callResponse )
import Control.Distributed.Process.Closure ( mkClosure, remotable )

import Control.Exception ( SomeException )
import Data.List ( foldl' )


-- | The update function of the Multimap.
updateStore :: [StoreUpdate] -> Multimap -> Multimap
updateStore = flip $ foldl' $ flip applyUpdate
  where
    applyUpdate :: StoreUpdate -> Multimap -> Multimap
    applyUpdate (InsertMany kvs) = insertMany kvs
    applyUpdate (DeleteValues kvs) = deleteValues kvs
    applyUpdate (DeleteKeys ks) = deleteKeys ks

remotable [ 'updateStore ]

-- | Starts a loop which listens for incoming rpc calls
-- to query and modify the 'Multimap' in the replicated state.
multimap :: RGroup g => g Multimap -> Process ()
multimap rg = go
  where
    go = receiveWait
          [ callResponse $ \upds -> do
              updateStateWith rg $ $(mkClosure 'updateStore) (upds :: [StoreUpdate])
              return (Just (), ())
            `catch` \e -> const (return (Nothing, ())) (e :: SomeException)

          , callResponse $ \() -> do
              kvs <- fmap toList $ getState rg
              return (Just kvs, ())
            `catch` \e -> const (return (Nothing, ())) (e :: SomeException)
          ]
         >> go
