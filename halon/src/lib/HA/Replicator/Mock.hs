-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Faked implementation of the replication API
--
-- This is used for unit tests.
--

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module HA.Replicator.Mock
  ( RLocalGroup
  , Replica
  , __remoteTableDecl
  ) where

import HA.Replicator ( RGroup(..) )

import Control.Distributed.Process
    ( unClosure
    , liftIO
    , unStatic
    , Process
    , NodeId
    , monitor
    , getSelfPid
    , getSelfNode
    )
import Control.Distributed.Process.Closure
    ( mkStatic, remotableDecl )
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Control.Distributed.Process.Serializable
           ( SerializableDict(..) )
import Control.Distributed.Static ( closure )

import Data.Binary ( decode, encode )
import Data.ByteString.Lazy ( ByteString )
import Data.IORef ( IORef, readIORef, newIORef, atomicModifyIORef )
import Data.IntMap (IntMap)
import qualified Data.IntMap as Map
import Data.Typeable ( Typeable )
import System.IO.Unsafe
import Unsafe.Coerce


-- | Type of replication groups with states of type @st@.
--
-- A replication group is composed of one or more processes called replicas.
--
data RLocalGroup st where
  RLocalGroup :: Typeable st => IORef st -> [NodeId] -> RLocalGroup st
 deriving Typeable

data Some f = forall a. Some (f a) deriving (Typeable)

-- | Holds the generator of groups keys and a map of local groups.
-- Once a group is created it can be referenced by key in any node
-- running on the same unix process.
{-# NOINLINE globalRLocalGroups #-}
globalRLocalGroups :: IORef (Int, IntMap (Some RLocalGroup))
globalRLocalGroups = unsafePerformIO $ newIORef (0, Map.empty)

remotableDecl [ [d|

  createRLocalGroup :: forall st. ByteString -> Process (RLocalGroup st)
  createRLocalGroup bs = do
      let k = decode bs
      liftIO $ atomicModifyIORef globalRLocalGroups $ \(i, m) ->
        ((i, m), case m Map.! k of Some rg -> unsafeCoerce rg)
 |] ]

instance RGroup RLocalGroup where

  data Replica RLocalGroup = Replica

  newRGroup sd _ _snapshotThreashold _snapshotTimeout _leaseDuration ns st = do
    r <- liftIO $ newIORef st
    SerializableDict <- unStatic sd
    k <- liftIO $ atomicModifyIORef globalRLocalGroups $ \(i, m) ->
           ((i + 1, Map.insert i (Some $ RLocalGroup r ns) m), i)
    return $ closure $(mkStatic 'createRLocalGroup) (encode k)

  spawnReplica _ _ _ = error "Mock.spawnReplica: unimplemented"

  killReplica _ _ = return ()

  getRGroupMembers = error "Mock.getRGroupMembers: unimplemented"

  setRGroupMembers _ _ _ = return []

  updateRGroup _ Replica{} = return ()

  updateStateWith (RLocalGroup r _) cUpd = unClosure cUpd
    >>= \upd -> liftIO (atomicModifyIORef r $ \st -> seq st (upd st, ()))
    >> return True

  getState (RLocalGroup r _) = fmap Just $ liftIO $ readIORef r

  getStateWith (RLocalGroup r _) cRd = do
    s <- liftIO $ readIORef r
    f <- unClosure cRd
    f s
    return True

  monitorRGroup _ = getSelfPid >>= monitor

  monitorLocalLeader (RLocalGroup _ ns) = do
    here <- getSelfNode
    if [here] == take 1 ns then getSelfPid >>= monitor
      else monitor (nullProcessId here)

  getLeaderReplica (RLocalGroup _ []) = return Nothing
  getLeaderReplica (RLocalGroup _ (nid : _)) = return $ Just nid
