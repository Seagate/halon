-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Implements the process that manages the replicated multimap.
--

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Multimap.Process
    ( multimap, __remoteTable ) where

import HA.Multimap (StoreUpdate(..))
import HA.Multimap.Implementation
            ( Multimap, insertMany, deleteValues, deleteKeys, toList )
import HA.Replicator

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( mkClosure, remotable )
import Control.Distributed.Process.Scheduler ( schedulerIsEnabled )
import Control.Distributed.Process.Timeout ( retry, timeout )

import Control.Concurrent.MVar
import Control.Exception ( SomeException )
import Control.Monad ( when, void )
import Data.Binary ( encode )
import Data.ByteString ( ByteString )
import Data.ByteString.Builder ( lazyByteString, toLazyByteString )
import qualified Data.ByteString.Lazy as BSL ( ByteString )
import Data.ByteString.Lazy ( toChunks, fromChunks )
import Data.Function ( fix )
import Data.List ( foldl' )


-- | The update function of the Multimap.
updateStore :: [StoreUpdate] -> Multimap -> Multimap
updateStore = flip $ foldl' $ flip applyUpdate
  where
    applyUpdate :: StoreUpdate -> Multimap -> Multimap
    applyUpdate (InsertMany kvs) = insertMany kvs
    applyUpdate (DeleteValues kvs) = deleteValues kvs
    applyUpdate (DeleteKeys ks) = deleteKeys ks

-- | Sends the multimap in chunks to the given process.
readStore :: ProcessId -> Multimap -> Process ()
readStore caller mmap = void $ spawnLocal $ do
    link caller
    getSelfPid >>= usend caller
    -- For some reason, 'encode' from binary does not care to conflate the
    -- small bytestrings in the multimap. We merge these into reasonably
    -- sized chunks by using 'Data.ByteString.Builder.Builder'.
    mapM_ (usend caller) $ toChunks $
      toLazyByteString $ lazyByteString $ encode $ toList mmap
    usend caller ()
    -- We wait for the caller to finish reading the chunks,
    -- otherwise it may receive prematurely a notification of
    -- our death.
    expect

remotable [ 'updateStore, 'readStore ]

-- | Amount of microseconds between retries of requests for the replicated
-- state
requestTimeout :: Int
requestTimeout = 4 * 1000 * 1000

-- | Starts a loop which listens for incoming rpc calls
-- to query and modify the 'Multimap' in the replicated state.
multimap :: RGroup g => g Multimap -> Process ()
multimap rg = fix $ \go -> receiveWait
    [ match $ \(caller, upds) -> do
        retry requestTimeout $
          updateStateWith rg $
            $(mkClosure 'updateStore) (upds :: [StoreUpdate])
        usend caller (Just ())
      `catch` \e -> do
        usend caller (Nothing :: Maybe ())
        say ("MM: Writing failed: " ++ show (e :: SomeException))
    , match $ \(caller, ()) -> mask_ $ do
        -- Read the multimap from the replicated state.
        -- We need to handle here the case when the read request to
        -- replicas is lost and the case where the connection fails
        -- when the response is being sent.
        fix $ \retryLoop -> do
          mvRes <- liftIO newEmptyMVar
          readDone <- liftIO newEmptyMVar
          parent <- getSelfPid
          worker <- spawnLocal $ do
            getSelfPid >>= getStateWith rg . $(mkClosure 'readStore)
            reader <- expect
            ref <- monitor reader
            -- Signal that the read request was served.
            when schedulerIsEnabled $ usend parent ()
            liftIO $ putMVar readDone ()
            -- Read the response. If we get disconnected from the process which
            -- sends the chunks, consider the attempt failed and resend the read
            -- request.
            flip fix [] $ \loop xs -> receiveWait
              [ match $ \() -> do
                  when schedulerIsEnabled $ usend parent ()
                  liftIO $ putMVar mvRes $ Just $ fromChunks $ reverse xs
              , match $ \bs ->
                  loop (bs : xs :: [ByteString])
              , matchIf (\(ProcessMonitorNotification ref' _ _)
                          -> ref == ref') $
                  \_ -> do when schedulerIsEnabled $ usend parent ()
                           liftIO $ putMVar mvRes Nothing
              ]
            usend reader ()
          m <- if schedulerIsEnabled
            then expectTimeout requestTimeout
            else timeout requestTimeout $ liftIO $ takeMVar readDone
          case m of
            -- The read request timed out. Kill the worker and resend it.
            Nothing -> do
              blocked <- liftIO (tryPutMVar readDone ())
              when blocked $ exit worker "multimap retry" >> retryLoop
            Just () -> do
              when schedulerIsEnabled expect
              m' <- liftIO (takeMVar mvRes)
              case m' of
                -- We were disconnected while reading the response. Resend the
                -- read request.
                Nothing -> retryLoop
                Just bs -> usend caller $ Just bs
      `catch` \e -> do
        usend caller (Nothing :: Maybe BSL.ByteString)
        say ("MM: Reading failed: " ++ show (e :: SomeException))
    ] >> go
