-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Implements the process that manages the replicated multimap.
--

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Multimap.Process
    ( startMultimap, __remoteTable ) where

import HA.Debug
import HA.Logger (mkHalonTracer)
import HA.Multimap ( StoreUpdate(..), StoreChan(..), MetaInfo(..) )
import HA.Multimap.Implementation
            ( Multimap, insertMany, deleteValues, deleteKeys, toList )
import HA.Replicator

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( mkClosure, remotable )
import Control.Distributed.Process.Scheduler ( schedulerIsEnabled )
import Control.Distributed.Process.Timeout ( timeout )

import Control.Concurrent.MVar
import Control.Concurrent.STM.TChan
import Control.Exception (SomeException, throwIO)
import Control.Monad ( when, void )
import qualified Control.Monad.Catch as C
import Control.Monad.STM
import Data.Binary ( encode )
import Data.ByteString ( ByteString )
import Data.ByteString.Builder ( lazyByteString, toLazyByteString )
import Data.ByteString.Lazy ( toChunks, fromChunks )
import qualified Data.ByteString.Lazy as BSL ( length )
import Data.Function ( fix )
import Data.Maybe ( fromMaybe, listToMaybe )
import Data.List ( foldl' )

mmTrace :: String -> Process ()
mmTrace = mkHalonTracer "MM"

-- | The update function of the Multimap.
updateStore :: [StoreUpdate] -> (MetaInfo, Multimap) -> (MetaInfo, Multimap)
updateStore su (mi, mm) = (newMI, foldl' (flip applyUpdate) mm su)
  where
    applyUpdate :: StoreUpdate -> Multimap -> Multimap
    applyUpdate (InsertMany kvs) = insertMany kvs
    applyUpdate (DeleteValues kvs) = deleteValues kvs
    applyUpdate (DeleteKeys ks) = deleteKeys ks
    applyUpdate (SetMetaInfo{}) = id

    newMI = fromMaybe mi $ listToMaybe [ m | SetMetaInfo m <- su ]

-- | Sends the multimap in chunks to the given process.
readStore :: ProcessId -> (MetaInfo, Multimap) -> Process ()
readStore caller (mi, mmap) = void $ spawnLocalName "ha:multimap:reader" $ do
    link caller
    getSelfPid >>= usend caller
    -- For some reason, 'encode' from binary does not care to conflate the
    -- small bytestrings in the multimap. We merge these into reasonably
    -- sized chunks by using 'Data.ByteString.Builder.Builder'.
    mapM_ (usend caller) $ toChunks $
      toLazyByteString $ lazyByteString $ encode $ toList mmap
    -- Send metainfo in the end, also marking the end of the MM stream
    usend caller mi
    -- We wait for the caller to finish reading the chunks,
    -- otherwise it may receive prematurely a notification of
    -- our death.
    expect


remotable [ 'updateStore, 'readStore ]

-- | Amount of microseconds between retries of requests for the replicated
-- state
requestTimeout :: Int
requestTimeout = 4 * 1000 * 1000

bToM :: Bool -> Maybe ()
bToM True  = Just ()
bToM False = Nothing

-- | Starts a process which listens for incoming rpc calls
-- to query and modify the 'Multimap' in the replicated state.
--
-- The given function is used to setup the multimap process. It takes the main
-- loop as argument and it offers an oportunity to run a custom setup before
-- entering the loop.
startMultimap :: RGroup g => g (MetaInfo, Multimap)
                          -> (forall a. Process a -> Process a)
                          -> Process (ProcessId, StoreChan)
startMultimap rg f = mdo
    mmchan <- liftIO $ StoreChan mmpid <$> newTChanIO <*> newTChanIO
    mmpid <- spawnLocalName "ha:multimap" $ f $ multimap mmchan rg
    return (mmpid, mmchan)

-- | Starts a loop which listens for incoming rpc calls
-- to query and modify the 'Multimap' in the replicated state.
--
-- All updates to the replicated state are queued in the mailbox
-- and replicated together.
multimap :: RGroup g => StoreChan -> g (MetaInfo, Multimap) -> Process ()
multimap (StoreChan _ rchan wchan) rg =
    flip C.finally (mmTrace "terminated") $
    flip C.catch (\e -> do mmTrace $ "exception " ++ show (e :: SomeException)
                           liftIO $ throwIO e
                 ) $
    fix $ \go ->
    when schedulerIsEnabled (expect :: Process ()) >>
    liftIO (atomically $
               fmap Left (readTChan wchan) `orElse` fmap Right (readTChan rchan)
             ) >>= either
      (\upds_cb ->
        -- acc is the list with all the updates that have not been
        -- submitted for replication yet. It is never empty.
        flip fix [upds_cb] $ \readBatch acc -> do
          mupds <- liftIO $ atomically $ tryReadTChan wchan
          case mupds of
            -- There are no more queued updates in the mailbox.
            -- Replicate the updates we got.
            Nothing -> do
              mmTrace $ "replicating " ++ show (length acc) ++ " updates"
              flip fix (concat $ reverse $ map fst acc) $ \loop rs -> do
                -- Pick updates until the size of the encoding exceeds a
                -- threshold. Otherwise, creating too large batches would slow
                -- down replicas.
                let (rs', rest) =
                       (\p -> if null (fst p) then splitAt 1 (snd p) else p) $
                       (\(a, b) -> (map snd a, map snd b)) $
                       break ((> 64 * 1024) . fst) $
                       zip (scanl1 (+) $ map (BSL.length . encode) rs) rs
                retryRGroup rg requestTimeout $ fmap bToM $ updateStateWith rg $
                  $(mkClosure 'updateStore) rs'
                when (not $ null rest) $ loop rest

              mmTrace "running callbacks"
              mapM_ snd acc
              mmTrace "finished running callbacks"
            -- Accumulate the update with the others.
            Just upds_cb' -> do
              when schedulerIsEnabled (expect :: Process ())
              readBatch (upds_cb' : acc)
      )
      (\caller -> C.mask_ $ do
        -- Read the multimap from the replicated state.
        -- We need to handle here the case when the read request to
        -- replicas is lost and the case where the connection fails
        -- when the response is being sent.
        mmTrace "reading"
        fix $ \retryLoop -> do
          mmTrace "retrying"
          (sp, rp) <- newChan
          mvRes <- liftIO newEmptyMVar
          readDone <- liftIO newEmptyMVar
          worker <- spawnLocalName "ha:multimap:worker" $ do
            fix $ \loop ->
              getSelfPid >>= getStateWith rg . $(mkClosure 'readStore)
              >>= \b -> if b then return () else loop
            reader <- expect
            ref <- monitor reader
            -- Signal that the read request was served.
            when schedulerIsEnabled $ sendChan sp ()
            liftIO $ putMVar readDone ()
            -- Read the response. If we get disconnected from the process which
            -- sends the chunks, consider the attempt failed and resend the read
            -- request.
            flip fix [] $ \loop xs -> receiveWait
              [ match $ \(mi :: MetaInfo) -> do
                  when schedulerIsEnabled $ sendChan sp ()
                  liftIO $ putMVar mvRes $ Just (mi, fromChunks $ reverse xs)
              , match $ \bs ->
                  loop (bs : xs :: [ByteString])
              , matchIf (\(ProcessMonitorNotification ref' _ _)
                          -> ref == ref') $
                  \_ -> do when schedulerIsEnabled $ sendChan sp ()
                           liftIO $ putMVar mvRes Nothing
              ]
            usend reader ()
          mmTrace "waiting read signal"
          m <- if schedulerIsEnabled
            then receiveChanTimeout requestTimeout rp
            else timeout requestTimeout $ liftIO $ takeMVar readDone
          case m of
            -- The read request timed out. Kill the worker and resend it.
            Nothing -> do
              blocked <- liftIO (tryPutMVar readDone ())
              when blocked $ exit worker "multimap retry" >> retryLoop
            Just () -> do
              mmTrace "waiting read result"
              when schedulerIsEnabled $ receiveChan rp
              m' <- liftIO (takeMVar mvRes)
              case m' of
                -- We were disconnected while reading the response. Resend the
                -- read request.
                Nothing -> retryLoop
                Just mibs -> mmTrace "finished reading" >> usend caller mibs
    ) >> go
