 -- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-unused-binds -fno-warn-orphans #-}
module HA.Startup where

import HA.RecoverySupervisor ( recoverySupervisor, RSState(..) )
import HA.EventQueue ( EventQueue, eventQueueLabel )
import HA.EventQueue.Definitions (eventQueue)
import qualified HA.EQTracker as EQT
import HA.Multimap.Implementation ( Multimap, fromList )
import HA.Multimap.Process ( multimap )
import HA.Replicator ( RGroup(..), RStateView(..) )
import HA.Replicator.Log ( RLogGroup )
import qualified HA.Storage as Storage

import Control.Arrow ( first, second, (***) )
import Control.Distributed.Process
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
import Control.Distributed.Process.Timeout ( retry )
import Control.Distributed.Static ( closureApply )
import Control.Exception (SomeException)

import Data.Binary ( decode, encode )
import Data.ByteString.Lazy (ByteString)
import Data.List ( partition )
import Data.Maybe ( isJust )

import qualified Network.Transport as NT
import qualified Data.Map as Map ( toList, empty )
import Control.Monad.Reader
import System.IO (hPutStrLn, stderr)


getGlobalRGroup :: Process (Maybe (Closure (Process (RLogGroup HAReplicatedState))))
getGlobalRGroup = either (const Nothing) Just <$> Storage.get "global-rgroup"

putGlobalRGroup :: Closure (Process (RLogGroup HAReplicatedState))
                -> Process ()
putGlobalRGroup = Storage.put "global-rgroup"

-- | Replicated state of the HA
type HAReplicatedState = (RSState,(EventQueue,Multimap))

rsView :: RStateView HAReplicatedState RSState
rsView = RStateView fst first

eqView :: RStateView HAReplicatedState EventQueue
eqView = RStateView (fst . snd) (second . first)

multimapView :: RStateView HAReplicatedState Multimap
multimapView = RStateView (snd . snd) (second . second)

rsDict :: SerializableDict HAReplicatedState
rsDict = SerializableDict

decodeNids :: ByteString -> [NodeId]
decodeNids = decode

remotable [ 'rsView, 'eqView, 'multimapView, 'rsDict, 'decodeNids ]

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
   r <- isJust <$> getGlobalRGroup
   usend caller r

 isNodeInGroup :: [NodeId] -> NodeId -> Bool
 isNodeInGroup = flip elem

 addNodes :: ( ProcessId -- ^ Caller
             , [NodeId]
             , [NodeId] -- ^ (New nodes, existing trackers)
             , Closure (ProcessId -> ProcessId -> Process ())
             )
          -> Process ()
 addNodes (caller, newNodes, trackers, rcClosure) = do
     disconnectAllNodeConnections
     mcRGroup <- getGlobalRGroup
     case mcRGroup of
       Just cRGroup -> do
         rGroup <- unClosure cRGroup >>= id
         replicas <- setRGroupMembers rGroup newNodes $
                          $(mkClosure 'isNodeInGroup) $ trackers

         (sp, rp) <- newChan
         forM_ (zip newNodes replicas) $ \(n,replica) -> spawn
                  n
                  $ $(mkClosure 'startRS)
                      (cRGroup, Just replica, rcClosure, sp :: SendPort ())
         forM_ replicas $ \_ -> receiveChan rp
       Nothing -> return ()
     usend caller ()


 startRS :: ( Closure (Process (RLogGroup HAReplicatedState))
            , Maybe (Replica RLogGroup)
            , Closure (ProcessId -> ProcessId -> Process ())
            , SendPort ()
            )
            -> Process ()
 startRS (cRGroup, mlocalReplica, rcClosure, sp) = do
     rGroup <- unClosure cRGroup >>= id
     recoveryCoordinator <- unClosure rcClosure
     maybe (return ()) (updateRGroup rGroup) mlocalReplica
     putGlobalRGroup cRGroup
     eqpid <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
     rspid <- spawnLocal $ do
       -- Killing RS when EQ dies, helps cleaning up in tests.
       link eqpid
       recoverySupervisor (viewRState $(mkStatic 'rsView) rGroup) $
         mask_ $ do
           rcpid <- getSelfPid
           mmpid <- spawnLocal $ do
             link rcpid
             multimap (viewRState $(mkStatic 'multimapView) rGroup)
           usend eqpid rcpid
           recoveryCoordinator eqpid mmpid

     -- monitoring processes is okay, since these
     -- processes are on the same node, we're not
     -- depending on heartbeats at the transport layer
     void $ spawnLocal $ do
       rsref <- monitor rspid
       let refmapper ref | ref == rsref = "Recovery supervisor died"
                         | otherwise = "Unknown subprocess died"
       handleMessages refmapper
     sendChan sp ()
  where
     handleMessages refmapper =
       receiveWait [
         match (\(ProcessMonitorNotification ref _ _) ->
           liftIO (hPutStrLn stderr (refmapper ref)) >>
           return ())
       ] >> handleMessages refmapper

 -- | Start the RC and EQ.
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
             , Closure (ProcessId -> ProcessId -> Process ())
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
      cRGroup <- newRGroup $(mkStatic 'rsDict) snapshotThreshold snapshotTimeout
                           trackers
                           ( RSState Nothing 0 rsLeaderLease
                           , ((Nothing,[]),fromList [])
                           )
      (sp, rp) <- newChan
      forM_ trackers $ flip spawn $ $(mkClosure 'startRS)
          ( cRGroup :: Closure (Process (RLogGroup HAReplicatedState))
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

 autoboot :: Closure ([NodeId] -> ProcessId -> ProcessId -> Process ())
          -> Process ()
 autoboot rcClosure = do
    nid <- getSelfNode
    cRGroup <- spawnReplica $(mkStatic 'rsDict) nid
    rGroup <- unClosure cRGroup >>= id
    nids <- retry 1000000 $ getRGroupMembers rGroup
    let rcClosure' = rcClosure `closureApply` (closure
                                                $(mkStatic 'decodeNids)
                                                (encode nids)
                                              )
    (sp, rp) <- newChan
    void $ spawn nid $ $(mkClosure 'startRS)
          ( cRGroup :: Closure (Process (RLogGroup HAReplicatedState))
          , Nothing :: Maybe (Replica RLogGroup)
          , rcClosure'
          , sp:: SendPort ()
          )
    receiveChan rp

 |] ]

-- | Startup Halon node. This method run autoboot and starts all
-- processes that are required for halon node functionality.
startupHalonNode :: Closure ([NodeId] -> ProcessId -> ProcessId -> Process ())
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
        -- kill replica
        mcRGroup <- getGlobalRGroup
        case mcRGroup of
          Just cRGroup -> do
            rGroup <- join $ unClosure cRGroup
            getSelfNode >>= killReplica rGroup
          Nothing -> return ()
        -- kill storage
        kill st "stopHalonNode called"
        ref <- monitor st
        void $ receiveWait
          [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                    return
          ]
      Nothing -> return ()
