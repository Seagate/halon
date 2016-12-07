 -- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}
module HA.Startup where

import HA.RecoverySupervisor ( recoverySupervisor )
import HA.EventQueue.Process ( EventQueue, eventQueueLabel, startEventQueue, emptyEventQueue )
import qualified HA.EQTracker as EQT
import HA.Logger
import HA.Multimap ( MetaInfo, defaultMetaInfo, StoreChan )
import HA.Multimap.Implementation ( Multimap, fromList )
import HA.Multimap.Process ( startMultimap )
import HA.Replicator ( RGroup(..), retryRGroup )
import HA.Replicator.Log ( RLogGroup )
import qualified HA.Storage as Storage

import Control.Arrow ( (***) )
import Control.Distributed.Process hiding (mask_, catch)
import Control.Distributed.Process.Closure
  ( remotable
  , remotableDecl
  , mkClosure
  , mkStatic
  )
import qualified Control.Distributed.Process.Internal.StrictMVar as StrictMVar
    ( modifyMVar_ )
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Control.Distributed.Static ( closureApply )
import Control.Monad.Catch

import Data.Binary ( decode, encode )
import Data.ByteString.Lazy (ByteString)
import Data.List ( partition )
import Data.Maybe ( isJust )

import qualified Network.Transport as NT
import qualified Data.Map as Map ( toList, empty )
import Control.Monad.Reader
import System.IO (hPutStrLn, stderr)



startupTrace :: String -> Process ()
startupTrace = mkHalonTracer "startup"

getGlobalRGroups :: Process (Maybe
    ( Closure (Process (RLogGroup EventQueue))
    , Closure (Process (RLogGroup (MetaInfo, Multimap)))
    ))
getGlobalRGroups = either (const Nothing) Just <$> Storage.get "global-rgroup"

putGlobalRGroups :: ( Closure (Process (RLogGroup EventQueue))
                    , Closure (Process (RLogGroup (MetaInfo, Multimap)))
                    )
                 -> Process ()
putGlobalRGroups = Storage.put "global-rgroup"

eqDict :: SerializableDict EventQueue
eqDict = SerializableDict

mmDict :: SerializableDict (MetaInfo, Multimap)
mmDict = SerializableDict

decodeNids :: ByteString -> [NodeId]
decodeNids = decode

remotable [ 'eqDict, 'mmDict, 'decodeNids ]

-- | Closes all transport connections from the current node.
--
-- This is used to workaround a problem when using 'call'
-- from multiple process having the same NodeId.
--
disconnectAllNodeConnections :: Process ()
disconnectAllNodeConnections = do
    node <- fmap processNode ask
    liftIO $ StrictMVar.modifyMVar_ (localState node) $ \st -> do
      case st of
        LocalNodeValid vst -> do
          mapM_ closeIfNodeId . Map.toList $ _localConnections vst
          return $ LocalNodeValid vst{ _localConnections = Map.empty }
        _ -> return st
  where
    closeIfNodeId ((NodeIdentifier _,_),(c,_)) = NT.close c
    closeIfNodeId _ = return ()

remotableDecl [ [d|

 isSelfInGroup :: ProcessId -> Process ()
 isSelfInGroup caller = do
   r <- isJust <$> getGlobalRGroups
   usend caller r

 isNodeInGroup :: [NodeId] -> NodeId -> Bool
 isNodeInGroup = flip elem

 -- Gets the membership of the tracking station.
 --
 -- The result is sent through the given 'SendPort'. Yields 'Nothing' if
 -- the local node is not a tracking station node.
 getTrackingStationMembership :: SendPort (Maybe [NodeId]) -> Process ()
 getTrackingStationMembership sp = do
     mcRGroup <- getGlobalRGroups
     case mcRGroup of
       Just (cEQGroup, _) -> do
         eqGroup <- join $ unClosure cEQGroup
         eqNids <- retryRGroup eqGroup 1000000 $ getRGroupMembers eqGroup
         sendChan sp (Just eqNids)
       _ ->
         sendChan sp Nothing

 addNodes :: ( ProcessId
             , [NodeId]
             , [NodeId]
             , Closure (ProcessId -> StoreChan -> Process ())
             )
          -> Process ()
 addNodes (caller, newNodes, trackers, rcClosure) = do
     disconnectAllNodeConnections
     mcRGroup <- getGlobalRGroups
     case mcRGroup of
       Just (cEQGroup, cMMGroup) -> do
         eqGroup <- unClosure cEQGroup >>= id
         mmGroup <- unClosure cMMGroup >>= id
         reps1 <- setRGroupMembers eqGroup newNodes $
                      $(mkClosure 'isNodeInGroup) $ trackers
         reps2 <- setRGroupMembers mmGroup newNodes $
                      $(mkClosure 'isNodeInGroup) $ trackers

         (sp, rp) <- newChan
         forM_ (zip3 newNodes reps1 reps2) $ \(n, r1, r2) -> spawn
                  n
                  $ $(mkClosure 'startRS)
                      ( cEQGroup, cMMGroup
                      , Just (r1, r2)
                      , rcClosure
                      , sp :: SendPort ()
                      )
         forM_ newNodes $ \_ -> receiveChan rp
       Nothing -> return ()
     usend caller ()


 startRS :: ( Closure (Process (RLogGroup EventQueue))
            , Closure (Process (RLogGroup (MetaInfo, Multimap)))
            , Maybe (Replica RLogGroup, Replica RLogGroup)
            , Closure (ProcessId -> StoreChan -> Process ())
            , SendPort ()
            )
            -> Process ()
 startRS (cEQGroup, cMMGroup, mlocalReplicas, rcClosure, sp) = do
     startupTrace "startRS"
     eqGroup <- join $ unClosure cEQGroup
     mmGroup <- join $ unClosure cMMGroup
     recoveryCoordinator <- unClosure rcClosure
     startupTrace "startRS: updateRGroup"
     forM_ mlocalReplicas $ \(r1, r2) -> do
       updateRGroup eqGroup r1
       updateRGroup mmGroup r2
     startupTrace "startRS: putGlobalRGroups"
     putGlobalRGroups (cEQGroup, cMMGroup)
     startupTrace "startRS: startEventQueue"
     eqpid <- startEventQueue eqGroup
     rspid <- spawnLocal $ do
       -- Killing RS when EQ dies, helps cleaning up in tests.
       link eqpid
       recoverySupervisor mmGroup $
         mask_ $ do
           rcpid <- getSelfPid
           (mmpid, mmchan) <- startMultimap mmGroup
             $ \loop -> link rcpid >> loop
           usend eqpid rcpid
           link mmpid
           recoveryCoordinator eqpid mmchan

     -- monitoring processes is okay, since these
     -- processes are on the same node, we're not
     -- depending on heartbeats at the transport layer
     void $ spawnLocal $ do
       rsref <- monitor rspid
       let refmapper ref | ref == rsref = "Recovery supervisor died"
                         | otherwise = "Unknown subprocess died"
       handleMessages refmapper
     sendChan sp ()
     startupTrace "startRS: done"
  where
     handleMessages refmapper =
       receiveWait [
         match (\pmn@(ProcessMonitorNotification ref _ _) ->
           liftIO (hPutStrLn stderr (refmapper ref ++ " " ++ show pmn)) >>
           return ())
       ] >> handleMessages refmapper

 -- Start the RC and EQ.
 --
 -- Takes a tuple
 -- @(update, trackers, snapshotThreashold,
 --   snapshotTimeout, rcClosure, rsLeaderLease)@.
 --
 -- @update@ indicates if an existing tracking station is being updated.
 --
 -- @trackers@ is a list of node identifiers of tracking station nodes.
 --
 -- @snapshotThreashold@ indicates how many updates are allowed between
 -- snapshots of the distributed state.
 --
 -- @snapshotTimeout@ indicates how many microseconds to wait before giving up
 -- in trasferring a snapshot between nodes.
 --
 -- @rcClosure@ is the closure which runs the recovery coordinator. It
 -- takes the event queue and the multimap 'ProcessId's.
 --
 -- @rsLeaderLease@ is the lease of the leader RS in microseconds.
 --
 ignition :: ( Bool
             , [NodeId]
             , Int
             , Int
             , Closure (ProcessId -> StoreChan -> Process ())
             , Int
             )
          -> Process (Maybe (Bool,[NodeId],[NodeId],[NodeId]))
 ignition (update, trackers, snapshotThreshold, snapshotTimeout, rcClosure
          , rsLeaderLease
          ) = callLocal $ do
    say "Ignition!"
    disconnectAllNodeConnections
    if update then do
      (members,newNodes) <- queryMembership trackers
      added <- case members of
        m : _ -> do
          self <- getSelfPid
          _ <- spawnAsync m $ $(mkClosure 'addNodes)
            (self, newNodes, trackers, rcClosure)
          () <- expect
          return True
        [] -> return False

      return $ Just (added,trackers,members,newNodes)
    else do
      cEQGroup <- newRGroup $(mkStatic 'eqDict) "eq" snapshotThreshold
                            snapshotTimeout rsLeaderLease trackers
                            emptyEventQueue
      cMMGroup <- newRGroup $(mkStatic 'mmDict) "mm" snapshotThreshold
                            snapshotTimeout rsLeaderLease trackers
                            (defaultMetaInfo, fromList [])
      (sp, rp) <- newChan
      forM_ trackers $ flip spawn $ $(mkClosure 'startRS)
          ( cEQGroup :: Closure (Process (RLogGroup EventQueue))
          , cMMGroup :: Closure (Process (RLogGroup (MetaInfo, Multimap)))
          , Nothing :: Maybe (Replica RLogGroup)
          , rcClosure
          , sp :: SendPort ()
          )
      forM_ trackers $ \_ -> receiveChan rp
      return Nothing

  where
    queryMembership nids = do
        self <- getSelfPid
        bs <- forM nids $ \nid -> do
            _ <- spawnAsync nid $ $(mkClosure 'isSelfInGroup) self
            expect
        return $ map snd *** map snd $ partition fst $ zip bs nids

 autoboot :: Closure ([NodeId] -> ProcessId -> StoreChan -> Process ())
          -> Process ()
 autoboot rcClosure = do
    nid <- getSelfNode
    startupTrace "autoboot: spawnReplica eq"
    cEQGroup <- spawnReplica $(mkStatic 'eqDict) "eq" nid
    say "autoboot: spawnReplica mm"
    cMMGroup <- spawnReplica $(mkStatic 'mmDict) "mm" nid
    eqGroup <- join $ unClosure cEQGroup
    mmGroup <- join $ unClosure cMMGroup
    startupTrace "autoboot: getRGroupMembers eq"
    _eqNids <- retryRGroup eqGroup 1000000 $ getRGroupMembers eqGroup
    startupTrace "autoboot: getRGroupMembers mm"
    mmNids <- retryRGroup mmGroup 1000000 $ getRGroupMembers mmGroup
    let rcClosure' = rcClosure `closureApply` closure $(mkStatic 'decodeNids)
                                                      (encode mmNids)
    (sp, rp) <- newChan
    startupTrace "autoboot: spawn startRS"
    void $ spawn nid $ $(mkClosure 'startRS)
          ( cEQGroup :: Closure (Process (RLogGroup EventQueue))
          , cMMGroup :: Closure (Process (RLogGroup (MetaInfo, Multimap)))
          , Nothing :: Maybe (Replica RLogGroup)
          , rcClosure'
          , sp:: SendPort ()
          )
    startupTrace "autoboot: waiting"
    receiveChan rp
    startupTrace "autoboot: done"

 |] ]

-- | Startup Halon node. This method run autoboot and starts all
-- processes that are required for halon node functionality.
startupHalonNode :: Closure ([NodeId] -> ProcessId -> StoreChan -> Process ())
                 -> Process ()
startupHalonNode rcClosure = do
    p <- Storage.runStorage
    link p

    autoboot rcClosure `catch` \(_ :: SomeException) ->
      say "No persisted state could be read. Starting in listen mode."
    void $ EQT.startEQTracker []

-- | Stops a Halon node.
stopHalonNode :: Process ()
stopHalonNode = do
    -- kill EQ
    meq <- whereis eventQueueLabel
    case meq of
      Just eq -> do
        kill eq "stopHalonNode called"
        ref <- monitor eq
        void $ receiveWait
          [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                    return
          ]
      Nothing -> return ()
    -- kill EQ tracker
    meqt <- whereis EQT.name
    case meqt of
      Just eqt -> do
        kill eqt "stopHalonNode called"
        ref <- monitor eqt
        void $ receiveWait
          [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                    return
          ]
      Nothing -> return ()
    mst <- whereis Storage.name
    case mst of
      Just st -> do
        -- kill replicas
        mcRGroup <- getGlobalRGroups
        case mcRGroup of
          Just (cEQGroup, cMMGroup) -> do
            eqGroup <- join $ unClosure cEQGroup
            mmGroup <- join $ unClosure cMMGroup
            getSelfNode >>= killReplica eqGroup
            getSelfNode >>= killReplica mmGroup
          Nothing -> return ()
        -- kill storage
        kill st "stopHalonNode called"
        ref <- monitor st
        void $ receiveWait
          [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                    return
          ]
      Nothing -> return ()
