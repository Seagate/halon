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

import HA.Replicator

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

import Control.Exception ( evaluate )
import Control.Monad ( when, forM, void, forM_ )
import Data.Binary ( decode, encode, Binary )
import Data.ByteString.Lazy ( ByteString )
import Data.Maybe (fromMaybe, isJust)
import Data.Ratio ( (%) )
import Data.Typeable ( Typeable )

import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)

-- | Implementation of RGroups on top of "Control.Distributed.State".
data RLogGroup st where
  RLogGroup :: (Typeable q, Typeable st)
            => Static (SerializableDict st)
            -> Static (SerializableDict q)
            -> String                       -- name of the group
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
    let (name, st0) = decode bs
     in State.log $ serializableSnapshot (snapshotServerLbl name) st0

snapshotServerLbl :: String -> String
snapshotServerLbl = ("snapshot-server." ++)

snapshotServer :: String -> Process ()
snapshotServer name =
    void $ serializableSnapshotServer (snapshotServerLbl name) $
             filepath $ storageDir </> "replica-snapshots" </> name

{-# NOINLINE storageDir #-}
storageDir :: FilePath
storageDir = unsafePerformIO $ do
  path <- fromMaybe "" <$> lookupEnv "HALON_PERSISTENCE"
  return $ path </> "halon-persistence"

halonPersistDirectory :: NodeId -> FilePath
halonPersistDirectory = filepath $ storageDir </> "replicas"

halonLogId :: String -> Log.LogId
halonLogId = Log.toLogId . ("halon-log." ++)

rgroupConfig :: (String, Int, Int) -> Log.Config
rgroupConfig (name, snapshotThreshold, snapshotTimeout) = Log.Config
    { logId             = halonLogId name
    , consensusProtocol =
          \dict -> BasicPaxos.protocol dict 3000000
                 (\n -> openPersistentStore
                            (filepath (storageDir </> "acceptors" </> name) n)
                          >>= acceptorStore
                 )
    , persistDirectory  = halonPersistDirectory
    , leaseTimeout      = 4000000
    , leaseRenewTimeout = 2000000
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreshold)
    , snapshotRestoreTimeout = snapshotTimeout
    }

bToM :: Bool -> Maybe ()
bToM True  = Just ()
bToM False = Nothing

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
         -> String
         -> Log.Handle (Command st)
         -> CommandPort st
         -> Process (RLogGroup st)
fromPort sdictState name h port = do
    return $ RLogGroup sdictState sdictState name h port
                    ($(mkStatic 'idRStateView) `staticApply` sdictState)
  where
    _ = $(functionSDict 'halonPersistDirectory) -- avoids unused warning

remotableDecl [ [d|

 createRLogGroup :: ByteString
                 -> SerializableDict st
                 -> Process (RLogGroup st)
 createRLogGroup bs SerializableDict = case decode bs of
   (sdictState, name, rHandle) -> do
      h <- Log.clone rHandle
      newPort h >>= fromPort sdictState name h

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

  newRGroup sdictState name snapshotThreshold snapshotTimeout nodes (st :: s)
      = do
    when (null nodes) $ do
      say "RLogGroup: newRGroup was passed an empty list of nodes."
      die "RLogGroup: newRGroup was passed an empty list of nodes."
    let cmSDictState = staticApply $(mkStatic 'commandSerializableDict)
                     $ staticApply $(mkStatic 'mstateTypeableDict) sdictState
        est = encode (name, st)
    forM_ nodes $ \n -> spawn n $ $(mkClosure 'snapshotServer) name
    Log.new
         $(mkStatic 'commandEqDict)
         cmSDictState
         ($(mkClosure 'rgroupConfig) (name, snapshotThreshold, snapshotTimeout))
         (closure ($(mkStatic 'rgroupLog) `staticApply` sdictState) est)
         nodes
    h <- Log.spawnReplicas (halonLogId name)
                           $(mkStaticClosure 'halonPersistDirectory)
                           nodes
    rHandle <- Log.remoteHandle (h :: Log.Handle (Command s))
    return $ (closure $(mkStatic 'createRLogGroup)
                                 $ encode (sdictState, name, rHandle))
                        `closureApply` staticClosure sdictState

  spawnReplica (sdictState :: Static (SerializableDict s)) name nid = do
    _ <- spawn nid $ $(mkClosure 'snapshotServer) name
    h <- Log.spawnReplicas (halonLogId name)
                           $(mkStaticClosure 'halonPersistDirectory)
                           [nid]
    rHandle <- Log.remoteHandle (h :: Log.Handle (Command s))
    return $ (closure $(mkStatic 'createRLogGroup)
                                 $ encode (sdictState, name, rHandle))
                        `closureApply` staticClosure sdictState

  killReplica (RLogGroup _ _ _ h _ _) nid = Log.killReplica h nid

  getRGroupMembers (RLogGroup _ _ _ h _ _) = Log.getMembership h

  setRGroupMembers rg@(RLogGroup _ _ name h _ _) ns inGroup = do
    say $ "setRGroupMembers: " ++ show ns
    retryRGroup rg 1000000 $ fmap bToM $
      Log.reconfigure h ($(mkClosure 'removeNodes) () `closureApply` inGroup)
    say "setRGroupMembers: removed nodes"
    forM ns $ \nid -> do
      say $ "setRGroupMembers: adding " ++ show nid
      _ <- spawn nid $ $(mkClosure 'snapshotServer) name
      retryRGroup rg 1000000 $ fmap bToM $ Log.addReplica h nid
      return $ Replica nid

  updateRGroup (RLogGroup _ _ _ h _ _) (Replica ρ) = Log.updateHandle h ρ

  updateStateWith (RLogGroup _ _ _ _ port rp) cUpd =
    State.update port $ updateClosure rp cUpd

  getState (RLogGroup sdict _ _ _ port rv) =
    select sdict port $ staticClosure $ queryStatic rv

  getStateWith (RLogGroup _ _ _ _ port rv) cRd =
    fmap isJust $ select sdictUnit port $
      $(mkStaticClosure 'composeM)
        `closureApply` staticClosure (queryStatic rv)
        `closureApply` cRd

  viewRState rv (RLogGroup _ sdq name h port rv') =
      RLogGroup ($(mkStatic 'rvDict) `staticApply` rv) sdq name h port $
                $(mkStatic 'composeSV) `staticApply` rv' `staticApply` rv

  monitorRGroup (RLogGroup _ _ _ h _ _) = Log.monitorLog h

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
