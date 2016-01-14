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

snapshotServer :: Process ()
snapshotServer = void $ serializableSnapshotServer
                    snapshotServerLbl
                    (filepath $ storageDir </> "replica-snapshots")

storageDir :: FilePath
storageDir = "halon-persistence"

halonPersistDirectory :: NodeId -> FilePath
halonPersistDirectory = filepath $ storageDir </> "replicas"

halonLogId :: Log.LogId
halonLogId = Log.toLogId "halon-log"

rgroupConfig :: (Int, Int) -> Log.Config
rgroupConfig (snapshotThreshold, snapshotTimeout) = Log.Config
    { logId             = halonLogId
    , consensusProtocol =
          \dict -> BasicPaxos.protocol dict 8000000
                 (\n -> openPersistentStore
                            (filepath (storageDir </> "acceptors") n) >>=
                        acceptorStore
                 )
    , persistDirectory  = halonPersistDirectory
    , leaseTimeout      = 8000000
    , leaseRenewTimeout = 6000000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreshold)
    , snapshotRestoreTimeout = snapshotTimeout
    }

composeM :: (a -> Process b) -> (b -> Process c) -> a -> Process c
composeM f g x = f x >>= g

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
          , 'halonPersistDirectory
          , 'composeM
          ]

fromPort :: Typeable st
         => Static (SerializableDict st)
         -> Log.Handle (Command st)
         -> CommandPort st
         -> Process (RLogGroup st)
fromPort sdictState h port = do
    return $ RLogGroup sdictState sdictState h port
                    ($(mkStatic 'idRStateView) `staticApply` sdictState)
  where
    _ = $(functionSDict 'halonPersistDirectory) -- avoids unused warning

remotableDecl [ [d|

 createRLogGroup :: ByteString
                 -> SerializableDict st
                 -> Process (RLogGroup st)
 createRLogGroup bs SerializableDict = case decode bs of
   (sdictState, rHandle) -> do
      h <- Log.clone rHandle
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

instance RGroup RLogGroup where

  newtype Replica RLogGroup = Replica NodeId
    deriving Binary

  newRGroup sdictState snapshotThreshold snapshotTimeout nodes (st :: s) = do
    when (null nodes) $ do
      say "RLogGroup: newRGroup was passed an empty list of nodes."
      die "RLogGroup: newRGroup was passed an empty list of nodes."
    let cmSDictState = staticApply $(mkStatic 'commandSerializableDict)
                     $ staticApply $(mkStatic 'mstateTypeableDict) sdictState
        est = encode st
    forM_ nodes $ \n -> spawn n $ staticClosure $(mkStatic 'snapshotServer)
    Log.new
         $(mkStatic 'commandEqDict)
         cmSDictState
         ($(mkClosure 'rgroupConfig) (snapshotThreshold, snapshotTimeout))
         (closure ($(mkStatic 'rgroupLog) `staticApply` sdictState) est)
         nodes
    h <- Log.spawnReplicas halonLogId
                           $(mkStaticClosure 'halonPersistDirectory)
                           nodes
    rHandle <- Log.remoteHandle (h :: Log.Handle (Command s))
    return $ (closure $(mkStatic 'createRLogGroup)
                                 $ encode (sdictState, rHandle))
                        `closureApply` staticClosure sdictState

  spawnReplica (sdictState :: Static (SerializableDict s)) nid = do
    _ <- spawn nid $ staticClosure $(mkStatic 'snapshotServer)
    h <- Log.spawnReplicas halonLogId
                           $(mkStaticClosure 'halonPersistDirectory)
                           [nid]
    rHandle <- Log.remoteHandle (h :: Log.Handle (Command s))
    return $ (closure $(mkStatic 'createRLogGroup)
                                 $ encode (sdictState, rHandle))
                        `closureApply` staticClosure sdictState

  killReplica (RLogGroup _ _ h _ _) nid = Log.killReplica h nid

  getRGroupMembers (RLogGroup _ _ h _ _) = Log.getMembership h

  setRGroupMembers (RLogGroup _ _ h _ _) ns inGroup = do
    Log.reconfigure h $ $(mkClosure 'removeNodes) () `closureApply` inGroup
    forM ns $ \nid -> do
      _ <- spawn nid $ staticClosure $(mkStatic 'snapshotServer)
      Log.addReplica h nid
      return $ Replica nid

  updateRGroup (RLogGroup _ _ h _ _) (Replica ρ) = Log.updateHandle h ρ

  updateStateWith (RLogGroup _ _ _ port rp) cUpd =
    State.update port $ updateClosure rp cUpd

  getState (RLogGroup sdict _ _ port rv) =
    select sdict port $ staticClosure $ queryStatic rv

  getStateWith (RLogGroup _ _ _ port rv) cRd =
    select sdictUnit port $
      $(mkStaticClosure 'composeM)
        `closureApply` staticClosure (queryStatic rv)
        `closureApply` cRd

  viewRState rv (RLogGroup _ sdq h port rv') =
      RLogGroup ($(mkStatic 'rvDict) `staticApply` rv) sdq h port $
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
