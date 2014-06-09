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
                                  , closureApply, staticClosure, closure
                                  )

import Data.Binary ( decode, encode )
import Data.ByteString.Lazy ( ByteString )
import Data.IORef ( IORef, readIORef, newIORef, atomicModifyIORef )
import Data.Typeable ( Typeable )


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

remotable [ 'composeRP, 'update, 'idRStateView ]

remotableDecl [ [d|

  createRLocalGroup :: ByteString -> SerializableDict st
                    -> Process (RLocalGroup st)
  createRLocalGroup bs SerializableDict = case decode bs of
      (sd,st) -> do
        liftIO $ fmap (flip RLocalGroup
                      $ staticApply $(mkStatic 'idRStateView) sd
                      ) $ newIORef st
 |] ]

-- | Provides a way to transform closures with views.
updateClosure :: (Typeable st,Typeable v) => Static (RStateView st v)
              -> Closure (v -> v) -> Closure (st -> st)
updateClosure rv c = (staticApply $(mkStatic 'update) rv) `closureApplyStatic` c

instance RGroup RLocalGroup where

  data Replica RLocalGroup = Replica

  newRGroup sd ns st = return $
      closure $(mkStatic 'createRLocalGroup) (encode (sd,st))
        `closureApply` staticClosure sd

  stopRGroup _ = return ()

  setRGroupMembers _ _ _ = return []

  updateRGroup _ _ = return ()

  updateStateWith (RLocalGroup r rp) cUpd = unClosure (updateClosure rp cUpd)
    >>= \upd -> liftIO $ atomicModifyIORef r $ \st -> seq st (upd st, ())

  getState (RLocalGroup r rv) = unStatic rv
    >>= \rgv -> fmap (prj rgv) $ liftIO $ readIORef r

  viewRState rv (RLocalGroup st rv') = RLocalGroup st $
    $(mkStatic 'composeRP) `staticApply` rv' `staticApply` rv
