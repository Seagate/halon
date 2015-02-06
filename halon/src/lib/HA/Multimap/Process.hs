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

import HA.Multimap (Key, Value, StoreUpdate(..))
import HA.Multimap.Implementation
            ( Multimap, insertMany, deleteValues, deleteKeys, toList )
import HA.Replicator ( RGroup, updateStateWith, getState )
import HA.System.Timeout ( retry )

import Control.Distributed.Process hiding (send)
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

-- | Amount of microseconds between retries of requests for the replicated
-- state
requestTimeout :: Int
requestTimeout = 1000 * 1000

-- | Starts a loop which listens for incoming rpc calls
-- to query and modify the 'Multimap' in the replicated state.
multimap :: RGroup g => g Multimap -> Process ()
multimap rg = go
  where
    go = receiveWait
        [ match $ \(caller, upds) -> do
              retry requestTimeout $
                updateStateWith rg $
                  $(mkClosure 'updateStore) (upds :: [StoreUpdate])
              usend caller (Just ())
            `catch` \e -> do
              usend caller (Nothing :: Maybe ())
              say ("MM: Writing failed: " ++ show (e :: SomeException))
        , match $ \(caller, ()) -> do
              kvs <- fmap toList $ retry requestTimeout $ getState rg
              usend caller (Just kvs)
            `catch` \e -> do
              usend caller (Nothing :: Maybe [(Key,[Value])])
              say ("MM: Reading failed: " ++ show (e :: SomeException))
        ] >> go
