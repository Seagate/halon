-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
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
module HA.Replicator.Mock
  ( RLocalGroup
  , Replica
  , __remoteTable
  , __remoteTableDecl
  ) where

import HA.Replicator ( RGroup(..), RStateView(..) )

import Control.Distributed.Process
    ( Static, Closure, unClosure, liftIO, unStatic, Process )
import Control.Distributed.Process.Closure
    ( remotable, mkStatic, remotableDecl )
import Control.Distributed.Process.Serializable
           ( Serializable, SerializableDict(..) )
import Control.Distributed.Static ( closureApplyStatic, staticApply
                                  , closure
                                  )

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
  RLocalGroup :: (Typeable st, Serializable q) => IORef q
              -> Static (RStateView q st) -> RLocalGroup st
 deriving Typeable

idRStateView :: SerializableDict st -> RStateView st st
idRStateView SerializableDict = RStateView id id

composeRP :: RStateView q v -> RStateView v w -> RStateView q w
composeRP (RStateView p0 u0) (RStateView p1 u1) =
    RStateView (p1 . p0) (u0 . u1)

data Some f = forall a. Some (f a) deriving (Typeable)

-- | Holds the generator of groups keys and a map of local groups.
-- Once a group is created it can be referenced by key in any node
-- running on the same unix process.
{-# NOINLINE globalRLocalGroups #-}
globalRLocalGroups :: IORef (Int, IntMap (Some RLocalGroup))
globalRLocalGroups = unsafePerformIO $ newIORef (0, Map.empty)

remotable [ 'composeRP, 'update, 'idRStateView ]

remotableDecl [ [d|

  createRLocalGroup :: ByteString -> Process (RLocalGroup st)
  createRLocalGroup bs = do
      let k = decode bs
      liftIO $ atomicModifyIORef globalRLocalGroups $ \(i, m) ->
        ((i, m), case m Map.! k of Some rg -> unsafeCoerce rg)
 |] ]

-- | Provides a way to transform closures with views.
updateClosure :: (Typeable st,Typeable v) => Static (RStateView st v)
              -> Closure (v -> v) -> Closure (st -> st)
updateClosure rv c = (staticApply $(mkStatic 'update) rv) `closureApplyStatic` c

instance RGroup RLocalGroup where

  data Replica RLocalGroup = Replica

  newRGroup sd _snapshotThreashold _snapshotTimeout _ns st = do
    r <- liftIO $ newIORef st
    SerializableDict <- unStatic sd
    k <- liftIO $ atomicModifyIORef globalRLocalGroups $ \(i, m) ->
           let rg = RLocalGroup r $ staticApply $(mkStatic 'idRStateView) sd
            in ((i + 1, Map.insert i (Some rg) m), i)
    return $ closure $(mkStatic 'createRLocalGroup) (encode k)

  spawnReplica _ _ = error "Mock.spawnReplica: unimplemented"

  killReplica _ _ = return ()

  getRGroupMembers = error "Mock.getRGroupMembers: unimplemented"

  setRGroupMembers _ _ _ = return []

  updateRGroup _ Replica{} = return ()

  updateStateWith (RLocalGroup r rp) cUpd = unClosure (updateClosure rp cUpd)
    >>= \upd -> liftIO $ atomicModifyIORef r $ \st -> seq st (upd st, ())

  getState (RLocalGroup r rv) = unStatic rv
    >>= \rgv -> fmap (prj rgv) $ liftIO $ readIORef r

  viewRState rv (RLocalGroup st rv') = RLocalGroup st $
    $(mkStatic 'composeRP) `staticApply` rv' `staticApply` rv
