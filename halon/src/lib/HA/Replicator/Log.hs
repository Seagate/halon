-- |
-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module HA.Replicator.Log
  ( RLogGroup
  , storageDir
  , replicasDir
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
  , say
  , die
  , NodeId
  , spawn
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types (nodeAddress)
import Control.Distributed.Static
  ( staticApply
  , staticClosure
  , closure
  , closureApply
  , closureCompose
  )

import Data.Constraint ( Dict(..) )

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
  RLogGroup :: Typeable st
            => Static (SerializableDict st)
            -> String                       -- name of the group
            -> Log.Handle (Command st)
            -> CommandPort st
            -> RLogGroup st
 deriving Typeable

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

replicasDir :: FilePath
replicasDir = storageDir </> "replicas"

halonPersistDirectory :: NodeId -> FilePath
halonPersistDirectory = filepath replicasDir

halonLogId :: String -> Log.LogId
halonLogId = Log.toLogId . ("halon-log." ++)

rgroupConfig :: (String, Int, Int, Int) -> Log.Config
rgroupConfig (name, snapshotThreshold, snapshotTimeout, leaseDuration) =
    Log.Config
    { logId             = halonLogId name
    , consensusProtocol =
          \dict -> BasicPaxos.protocol dict 3000000
                 (\n -> openPersistentStore
                            (filepath (storageDir </> "acceptors" </> name) n)
                          >>= acceptorStore
                 )
    , persistDirectory  = halonPersistDirectory
    , leaseTimeout      = leaseDuration
    , leaseRenewTimeout = leaseDuration `div` 2
    , driftSafetyFactor = 11 % 10
    , snapshotPolicy    = return . (>= snapshotThreshold)
    , snapshotRestoreTimeout = snapshotTimeout
    }

bToM :: Bool -> Maybe ()
bToM True  = Just ()
bToM False = Nothing

remotable [ 'commandSerializableDict
          , 'mstateTypeableDict
          , 'removeNodes
          , 'rgroupLog
          , 'rgroupConfig
          , 'snapshotServer
          , 'halonPersistDirectory
          ]

fromPort :: Typeable st
         => Static (SerializableDict st)
         -> String
         -> Log.Handle (Command st)
         -> CommandPort st
         -> Process (RLogGroup st)
fromPort sdictState name h port = do
    return $ RLogGroup sdictState name h port
  where
    _ = $(functionSDict 'halonPersistDirectory) -- avoids unused warning
    _ = $(functionTDict 'snapshotServer) -- avoids unused warning

remotableDecl [ [d|

 createRLogGroup :: forall st. ByteString
                 -> SerializableDict st
                 -> Process (RLogGroup st)
 createRLogGroup bs SerializableDict = case decode bs of
   (sdictState, name, rHandle) -> do
      h <- Log.clone rHandle
      newPort h >>= fromPort sdictState name h

  |] ]

instance RGroup RLogGroup where

  newtype Replica RLogGroup = Replica NodeId
    deriving Binary

  newRGroup sdictState name snapshotThreshold snapshotTimeout leaseDuration
            nodes (st :: s)
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
         ($(mkClosure 'rgroupConfig)
           (name, snapshotThreshold, snapshotTimeout, leaseDuration))
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

  killReplica (RLogGroup _ _ h _) nid = Log.killReplica h nid

  getRGroupMembers (RLogGroup _ _ h _) = Log.getMembership h

  setRGroupMembers rg@(RLogGroup _ name h _) ns inGroup = do
    say $ "setRGroupMembers: " ++ show ns
    retryRGroup rg 1000000 $ fmap bToM $
      Log.reconfigure h ($(mkClosure 'removeNodes) () `closureApply` inGroup)
    say "setRGroupMembers: removed nodes"
    forM ns $ \nid -> do
      say $ "setRGroupMembers: adding " ++ show nid
      _ <- spawn nid $ $(mkClosure 'snapshotServer) name
      retryRGroup rg 1000000 $ fmap bToM $ Log.addReplica h nid
      return $ Replica nid

  updateRGroup (RLogGroup _ _ h _) (Replica ρ) = Log.updateHandle h ρ

  updateStateWith (RLogGroup _ _ _ port) cUpd =
    State.update port $ closureCompose idCP cUpd

  getState (RLogGroup sdict _ _ port) = select sdict port idCP

  getStateWith (RLogGroup _ _ _ port) cRd =
    fmap isJust $ select sdictUnit port cRd

  monitorRGroup (RLogGroup _ _ h _) = Log.monitorLog h

  monitorLocalLeader (RLogGroup _ _ h _) = Log.monitorLocalLeader h

  getLeaderReplica (RLogGroup _ _ h _) = Log.getLeaderReplica h

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
