-- |
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Implementation of the replication interface on top of
-- "Control.Distributed.State".

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module HA.Replicator.Log
  ( RLogGroup
  , __remoteTable
  , __remoteTableDecl
  )  where

import HA.Replicator ( RGroup(..), RStateView(..) )

import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos
import qualified Control.Distributed.Log as Log
import Control.Distributed.Log.Persistence.LevelDB
import Control.Distributed.Log.Persistence.Paxos (acceptorStore)
import Control.Distributed.Log.Policy hiding ( __remoteTable )
import Control.Distributed.Log.Snapshot
  ( serializableSnapshot
  , serializableSnapshotServer
  )
import Control.Distributed.State
  ( CommandPort
  , newPort
  , commandEqDict
  , commandEqDict__static
  , select
  , Log
  , commandSerializableDict
  , Command
  )
import qualified Control.Distributed.State as State ( update, log )

import Control.Distributed.Process
  ( Process
  , Static
  , unStatic
  , Closure
  , liftIO
  , say
  , die
  , NodeId
  , spawn
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types (nodeAddress)
import Control.Distributed.Static
  ( closureApplyStatic
  , staticApply
  , staticClosure
  , closure
  , closureApply
  )

import Data.Constraint ( Dict(..) )

import System.FilePath ((</>))
import Control.Exception ( evaluate )
import Control.Monad ( when, forM, void, forM_ )
import Data.Binary ( decode, encode, Binary )
import Data.ByteString.Lazy ( ByteString )
import Data.Ratio ( (%) )
import Data.Typeable ( Typeable )

-- | Implementation of RGroups on top of "Control.Distributed.State".
data RLogGroup st where
  RLogGroup :: (Typeable q, Typeable st)
            => Static (SerializableDict st)
            -> Static (SerializableDict q)
            -> q
            -> Log.Handle (Command q)
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

mstateTypeableDict :: SerializableDict st -> Dict (Typeable st)
mstateTypeableDict SerializableDict = Dict

removeNodes :: () -> (NodeId -> Bool) -> NominationPolicy
removeNodes () np = filter np

filepath :: FilePath -> NodeId -> FilePath
filepath prefix nid = prefix </> show (nodeAddress nid)

rgroupLog :: SerializableDict st -> ByteString -> Log st
rgroupLog SerializableDict bs =
    State.log $ serializableSnapshot snapshotServerLbl (decode bs)

snapshotServerLbl :: String
snapshotServerLbl = "snapshot-server"

snapshotServer :: forall st . SerializableDict st -> ByteString -> Process ()
snapshotServer SerializableDict bs = void $ serializableSnapshotServer
                    snapshotServerLbl
                    (filepath $ storageDir </> "replica-snapshots")
                    (decode bs :: st)

storageDir :: FilePath
storageDir = "halon-persistence"

rgroupConfig :: (Int, Int) -> Log.Config
rgroupConfig (snapshotThreshold, snapshotTimeout) = Log.Config
    { logName           = "halon-log"
    , consensusProtocol =
          \dict -> BasicPaxos.protocol dict 3000000
                 (\n -> openPersistentStore
                            (filepath (storageDir </> "acceptors") n) >>=
                        acceptorStore
                 )
    , persistDirectory  = filepath $ storageDir </> "replicas"
    , leaseTimeout      = 3000000
    , leaseRenewTimeout = 1000000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreshold)
    , snapshotRestoreTimeout = snapshotTimeout
    }

remotable [ 'composeSV
          , 'updateProc
          , 'idRStateView
          , 'prjProc
          , 'commandSerializableDict
          , 'rvDict
          , 'mstateTypeableDict
          , 'removeNodes
          , 'rgroupLog
          , 'rgroupConfig
          , 'snapshotServer
          ]

fromPort :: Typeable st
         => Static (SerializableDict st)
         -> st
         -> Log.Handle (Command st)
         -> CommandPort st
         -> Process (RLogGroup st)
fromPort sdictState st0 h port = do
    return $ RLogGroup sdictState sdictState st0 h port
                    ($(mkStatic 'idRStateView) `staticApply` sdictState)

remotableDecl [ [d|

 createRLogGroup :: ByteString
                 -> SerializableDict st
                 -> Process (RLogGroup st)
 createRLogGroup bs SerializableDict = case decode bs of
   (sdictState, rHandle, st0) -> do
      h <- Log.clone rHandle
      newPort h >>= fromPort sdictState st0 h

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

instance RGroup RLogGroup where

  newtype Replica RLogGroup = Replica NodeId
    deriving Binary

  newRGroup sdictState snapshotThreshold snapshotTimeout nodes st = do
    when (null nodes) $ do
      say "RLogGroup: newRGroup was passed an empty list of nodes."
      die "RLogGroup: newRGroup was passed an empty list of nodes."
    let cmSDictState = staticApply $(mkStatic 'commandSerializableDict)
                     $ staticApply $(mkStatic 'mstateTypeableDict) sdictState
        est = encode st
    forM_ nodes $ \n -> spawn n $
      closure ($(mkStatic 'snapshotServer) `staticApply` sdictState) est
    h <- Log.new
         $(mkStatic 'commandEqDict)
         cmSDictState
         ($(mkClosure 'rgroupConfig) (snapshotThreshold, snapshotTimeout))
         (closure ($(mkStatic 'rgroupLog) `staticApply` sdictState) est)
         nodes
    rHandle <- Log.remoteHandle h
    return $ (closure $(mkStatic 'createRLogGroup)
                                 $ encode (sdictState, rHandle, st))
                        `closureApply` staticClosure sdictState

  stopRGroup _ = return ()

  setRGroupMembers (RLogGroup _ sdq q0 h _ _) ns inGroup = do
    Log.reconfigure h $ $(mkClosure 'removeNodes) () `closureApply` inGroup
    SerializableDict <- unStatic sdq
    forM ns $ \nid -> do
      _ <- spawn nid $ closure ($(mkStatic 'snapshotServer) `staticApply` sdq)
                     $ encode q0
      Log.addReplica h nid
      return $ Replica nid

  updateRGroup (RLogGroup _ _ _ h _ _) (Replica ρ) = Log.updateHandle h ρ

  updateStateWith (RLogGroup _ _ _ _ port rp) cUpd =
    State.update port $ updateClosure rp cUpd

  getState (RLogGroup sdict _ _ _ port rv) =
    select sdict port $ staticClosure $ queryStatic rv

  viewRState rv (RLogGroup _ sdq q0 h port rv') =
      RLogGroup ($(mkStatic 'rvDict) `staticApply` rv) sdq q0 h port $
                $(mkStatic 'composeSV) `staticApply` rv' `staticApply` rv

#if ! MIN_VERSION_base(4,7,0)
-- | The sole purpose of this type is to provide a typeable instance from
-- which to extract the package and the module name.
data T = T
 deriving Typeable

instance Typeable (Replica RLogGroup) where
  typeOf _ = mkTyCon3 packageName moduleName "Some"
             `mkTyConApp` [ typeOf1 (undefined :: RLogGroup a) ]
    where
      packageName = tyConPackage $ typeRepTyCon $ typeOf T
      moduleName = tyConModule $ typeRepTyCon $ typeOf T
#endif
