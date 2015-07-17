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
import HA.EventQueue ( EventQueue )
import HA.EventQueue.Definitions (eventQueue)
import HA.Multimap.Implementation ( Multimap, fromList )
import HA.Multimap.Process ( multimap )
import HA.Replicator ( RGroup(..), RStateView(..) )
import HA.Replicator.Log ( RLogGroup )

import Control.Arrow ( first, second, (***) )
import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Closure
  ( remotable
  , remotableDecl
  , mkClosure
  , mkStatic
  , functionTDict
  )
import qualified Control.Distributed.Process.Internal.StrictMVar as StrictMVar
    ( modifyMVar_ )
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Control.Distributed.Process.Timeout ( retry )
import Control.Distributed.Static ( closureApply )

import Data.Binary ( decode, encode )
import Data.ByteString.Lazy (ByteString)
import Data.IORef ( newIORef, writeIORef, readIORef, IORef )
import Data.List ( partition )
import Data.Maybe ( isJust )

import qualified Network.Transport as NT
import qualified Data.Map as Map ( toList, empty )
import Control.Monad.Reader

import System.IO.Unsafe ( unsafePerformIO )

{-# NOINLINE globalRGroup #-}
globalRGroup :: IORef (Maybe (Closure (Process (RLogGroup HAReplicatedState))))
globalRGroup = unsafePerformIO $ newIORef Nothing

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
      mapM_ closeIfNodeId . Map.toList $ _localConnections st
      return st { _localConnections = Map.empty }
  where
    closeIfNodeId ((NodeIdentifier _,_),(c,_)) = NT.close c
    closeIfNodeId _ = return ()

remotableDecl [ [d|

 isSelfInGroup :: () -> Process Bool
 isSelfInGroup () = liftIO $ fmap isJust $ readIORef globalRGroup

 isNodeInGroup :: [NodeId] -> NodeId -> Bool
 isNodeInGroup = flip elem

 addNodes :: ( [NodeId]
             , [NodeId] -- ^ (New nodes, existing trackers)
             , Closure (ProcessId -> ProcessId -> Process ())
             )
          -> Process ()
 addNodes (newNodes, trackers, rcClosure) = do
     disconnectAllNodeConnections
     mcRGroup <- liftIO $ readIORef globalRGroup
     case mcRGroup of
       Just cRGroup -> do
         rGroup <- unClosure cRGroup >>= id
         replicas <- setRGroupMembers rGroup newNodes $
                          $(mkClosure 'isNodeInGroup) $ trackers
         forM_ (zip newNodes replicas) $ \(n,replica) -> spawn
                  n
                  $ $(mkClosure 'startRS)
                      (cRGroup, Just replica, rcClosure)
       Nothing -> return ()


 startRS :: ( Closure (Process (RLogGroup HAReplicatedState))
            , Maybe (Replica RLogGroup)
            , Closure (ProcessId -> ProcessId -> Process ())
            )
            -> Process ()
 startRS (cRGroup, mlocalReplica, rcClosure) = do
     rGroup <- unClosure cRGroup >>= id
     recoveryCoordinator <- unClosure rcClosure
     maybe (return ()) (updateRGroup rGroup) mlocalReplica
     liftIO $ writeIORef globalRGroup $ Just cRGroup
     eqpid <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
     rspid <- spawnLocal
              $ recoverySupervisor (viewRState $(mkStatic 'rsView) rGroup)
              $ mask_ $ do
                rcpid <- getSelfPid
                mmpid <- spawnLocal $ do
                       link rcpid
                       multimap (viewRState $(mkStatic 'multimapView) rGroup)
                usend eqpid rcpid
                recoveryCoordinator eqpid mmpid

     -- monitoring processes is okay, since these
     -- processes are on the same node, we're not
     -- depending on heartbeats at the transport layer
     rsref <- monitor rspid
     let refmapper ref | ref == rsref = "Recovery supervisor died"
                       | otherwise = "Unknown subprocess died"
     handleMessages refmapper
  where
     handleMessages refmapper =
       receiveWait [
         match (\(ProcessMonitorNotification ref _ _) ->
           liftIO (putStrLn (refmapper ref)) >>
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
          ) = do
    say "Ignition!"
    disconnectAllNodeConnections
    if update then do
      (members,newNodes) <- queryMembership trackers
      added <- case members of
        m : _ -> do
          call $(functionTDict 'addNodes) m $
                 $(mkClosure 'addNodes) (newNodes, trackers, rcClosure)
          return True
        [] -> return False

      return $ Just (added,trackers,members,newNodes)
    else do
      cRGroup <- newRGroup $(mkStatic 'rsDict) snapshotThreshold snapshotTimeout
                           trackers
                           ( RSState Nothing 0 rsLeaderLease
                           , ((Nothing,[]),fromList [])
                           )
      forM_ trackers $ flip spawn $ $(mkClosure 'startRS)
          ( cRGroup :: Closure (Process (RLogGroup HAReplicatedState))
          , Nothing :: Maybe (Replica RLogGroup)
          , rcClosure
          )
      return Nothing

  where
    queryMembership nids = do
        bs <- forM nids $ \nid ->
            call $(functionTDict 'isSelfInGroup) nid $
                 $(mkClosure 'isSelfInGroup) ()
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
    void . spawn nid $ $(mkClosure 'startRS)
          ( cRGroup :: Closure (Process (RLogGroup HAReplicatedState))
          , Nothing :: Maybe (Replica RLogGroup)
          , rcClosure'
          )

 |] ]
