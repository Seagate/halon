-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Implementation of the replication interface on top of
-- "Control.Distributed.State".
--

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE CPP #-}
module HA.Replicator.Log
  ( RLogGroup
  , __remoteTable
  , __remoteTableDecl
  )  where

import HA.Replicator ( RGroup(..), RStateView(..) )

import Control.Distributed.Process.Consensus.BasicPaxos( protocolClosure )
import Control.Distributed.Log
           ( new, clone, remoteHandle, TypeableDict(..), sdictValue
           , addReplica, reconfigure, Handle, updateHandle
           )
import Control.Distributed.Log.Policy hiding ( __remoteTable )
import Control.Distributed.State
           ( CommandPort, newPort, commandEqDict, commandEqDict__static
           , select, Log, commandSerializableDict, Command
           )
import qualified Control.Distributed.State as State ( update, log )

import Control.Distributed.Process
    ( Process, Static, Closure, liftIO, say, die, ProcessId, NodeId
    , processNodeId
    )
import Control.Distributed.Process.Closure
           ( remotable, mkStatic, remotableDecl, mkClosure, mkStaticClosure )
import Control.Distributed.Process.Internal.Types (nodeAddress)
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Control.Distributed.Static
           ( closureApplyStatic, staticApply, staticClosure, closure
           , closureApply
           )

import Control.Arrow ( (***) )
import System.FilePath ((</>))
import Control.Exception ( evaluate )
import Control.Monad ( when, forM )
import Data.Binary ( decode, encode, Binary )
import Data.ByteString.Lazy ( ByteString )
#if MIN_VERSION_base(4,7,0)
import Data.Typeable ( Typeable )
#else
import Data.Typeable ( Typeable(..), mkTyConApp, mkTyCon3, tyConPackage
                     , tyConModule, typeRepTyCon, Typeable1(..)
                     )
#endif

-- | Implementation of RGroups on top of "Control.Distributed.State".
data RLogGroup st where
  RLogGroup :: (Typeable q, Typeable st) => Static (SerializableDict st)
            -> Handle (Command q)
            -> CommandPort q
            -> Static (RStateView q st)
            -> RLogGroup st
 deriving Typeable


rvDict :: RStateView st v -> SerializableDict v
rvDict (RStateView _ _) = SerializableDict

idRStateView :: SerializableDict st -> RStateView st st
idRStateView SerializableDict = RStateView id id

composeSV :: RStateView q v -> RStateView v w -> RStateView q w
composeSV (RStateView p0 u0) (RStateView p1 u1) =
    RStateView (p1 . p0) (u0 . u1)

prjProc :: RStateView st v -> st -> Process v
prjProc rv = return . prj rv

updateProc :: RStateView st v -> (v -> v) -> st -> Process st
updateProc rv f = liftIO . evaluate . update rv f

stateLog :: SerializableDict st -> ByteString -> Log st
stateLog SerializableDict = State.log . return . decode

mstateTypeableDict :: SerializableDict st -> TypeableDict st
mstateTypeableDict SerializableDict = TypeableDict

removeNodes :: () -> (NodeId -> Bool) -> NominationPolicy
removeNodes () np = filter (np . processNodeId)
                    ***
                    filter (np . processNodeId)

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

remotable [ 'composeSV, 'updateProc, 'idRStateView, 'prjProc, 'stateLog
          , 'commandSerializableDict, 'rvDict, 'mstateTypeableDict
          , 'removeNodes, 'filepath
          ]

fromPort :: Typeable st => Static (SerializableDict st)
         -> Handle (Command st)
         -> CommandPort st
         -> Process (RLogGroup st)
fromPort sdictState h port = do
    return $ RLogGroup sdictState h port
                    ($(mkStatic 'idRStateView) `staticApply` sdictState)

remotableDecl [ [d|

 createRLogGroup :: ByteString -> SerializableDict st -> Process (RLogGroup st)
 createRLogGroup bs SerializableDict = case decode bs of
   (sdictState,rHandle) -> do h <- clone rHandle
                              newPort h >>= fromPort sdictState h

  |] ]

-- | Provides a way to transform closures with views.
updateClosure :: (Typeable st,Typeable v) => Static (RStateView st v)
              -> Closure (v -> v) -> Closure (st -> Process st)
updateClosure rv c =
    staticApply $(mkStatic 'updateProc) rv `closureApplyStatic` c

-- | Provides a way to transform closures with views.
queryStatic :: (Typeable st,Typeable v) => Static (RStateView st v)
              -> Static (st -> Process v)
queryStatic rv = staticApply $(mkStatic 'prjProc) rv

-- | All replicas use the same lease renewal margin.
leaseRenewalMargin :: Int
leaseRenewalMargin = 1000000

instance RGroup RLogGroup where

  newtype Replica RLogGroup = Replica ProcessId
    deriving Binary

  newRGroup sdictState nodes st = do
    when (null nodes) $ do
      say "RLogGroup: newRGroup was passed an empty list of nodes."
      die "RLogGroup: newRGroup was passed an empty list of nodes."
    let cmSDictState = staticApply $(mkStatic 'commandSerializableDict)
                     $ staticApply $(mkStatic 'mstateTypeableDict)  sdictState
        storageDir = "acid-state"
    h <- new
         $(mkStatic 'commandEqDict)
         cmSDictState
         ($(mkClosure 'filepath) $ storageDir </> "replica")
         (protocolClosure (sdictValue cmSDictState)
              ($(mkClosure 'filepath) $ storageDir </> "acceptor"))
         (closure ($(mkStatic 'stateLog) `staticApply` sdictState) $ encode st)
         3000000
         leaseRenewalMargin
         nodes
    rHandle <- remoteHandle h
    return $ (closure $(mkStatic 'createRLogGroup)
                                 $ encode (sdictState,rHandle))
                        `closureApply` staticClosure sdictState

  stopRGroup _ = return ()

  setRGroupMembers (RLogGroup _ h _ _) ns inGroup = do
    reconfigure h $ $(mkClosure 'removeNodes) () `closureApply` inGroup
    forM ns $ \nid ->
      fmap Replica $ addReplica h $(mkStaticClosure 'orpn) nid
                                leaseRenewalMargin

  updateRGroup (RLogGroup _ h _ _) (Replica ρ) = updateHandle h ρ

  updateStateWith (RLogGroup _ _ port rp) cUpd =
    State.update port $ updateClosure rp cUpd

  getState (RLogGroup sdict _ port rv) =
    select sdict port $ staticClosure $ queryStatic rv

  viewRState rv (RLogGroup _ h port rv') =
      RLogGroup ($(mkStatic 'rvDict) `staticApply` rv) h port $
                $(mkStatic 'composeSV) `staticApply` rv' `staticApply` rv

-- | The sole purpose of this type is to provide a typeable instance from
-- which to extract the package and the module name.
#if ! MIN_VERSION_base(4,7,0)
data T = T
 deriving Typeable

instance Typeable (Replica RLogGroup) where
  typeOf _ = mkTyCon3 packageName moduleName "Some"
             `mkTyConApp` [ typeOf1 (undefined :: RLogGroup a) ]
    where
      packageName = tyConPackage $ typeRepTyCon $ typeOf T
      moduleName = tyConModule $ typeRepTyCon $ typeOf T
#endif
