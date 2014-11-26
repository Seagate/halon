-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-unused-binds -fno-warn-orphans #-}
module HA.RecoveryCoordinator.Mero.Startup where

import HA.NodeAgent (getNodeAgent)
import HA.RecoveryCoordinator.Mero (recoveryCoordinator, IgnitionArguments(..))
import HA.RecoverySupervisor ( recoverySupervisor, RSState(..) )
import HA.EventQueue ( eventQueue, EventQueue )
import HA.Multimap.Implementation ( Multimap, fromList )
import HA.Multimap.Process ( multimap )
#ifndef USE_RPC
import qualified HA.Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif
import HA.Replicator ( RGroup(..), RStateView(..) )
import HA.Replicator.Log ( RLogGroup )

import Control.Arrow ( first, second, (***) )
import Control.Concurrent.MVar ( newEmptyMVar, readMVar, putMVar )
import Control.Distributed.Process
import Control.Distributed.Process.Closure
    ( remotable, remotableDecl, mkStatic, mkClosure, functionTDict )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Data.Maybe ( catMaybes, isJust )
import qualified Mero.Genders

import Data.IORef ( newIORef, writeIORef, readIORef, IORef )
import Data.List ( partition )
import System.IO.Unsafe ( unsafePerformIO )

import Control.Distributed.Process.Internal.Types
import qualified Control.Distributed.Process.Internal.StrictMVar as StrictMVar
    ( modifyMVar_ )
import qualified Network.Transport as NT
import qualified Data.Map as Map ( toList, empty )
import Control.Monad.Reader

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

remotable [ 'rsView, 'eqView, 'multimapView, 'rsDict ]

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

 addNodes :: ([NodeId],[NodeId],[NodeId]) -> Process ()
 addNodes (newNodes,nodes,trackers) = do
     disconnectAllNodeConnections
     mcRGroup <- liftIO $ readIORef globalRGroup
     case mcRGroup of
       Just cRGroup -> do
         rGroup <- unClosure cRGroup >>= id
         replicas <- setRGroupMembers rGroup newNodes $
                          $(mkClosure 'isNodeInGroup) $ trackers
         forM_ (zip newNodes replicas) $ \(n,replica) -> spawn n $
                  $(mkClosure 'startRS)
                      (IgnitionArguments nodes trackers, cRGroup, Just replica)
       Nothing -> return ()

 startRS :: ( IgnitionArguments
            , Closure (Process (RLogGroup HAReplicatedState))
            , Maybe (Replica RLogGroup)
            )
         -> Process ()
 startRS (args,cRGroup,mlocalReplica) = do
     rGroup <- unClosure cRGroup >>= id
     maybe (return ()) (updateRGroup rGroup) mlocalReplica
     liftIO $ writeIORef globalRGroup $ Just cRGroup
     eqpid <- spawnLocal $ eventQueue (viewRState $(mkStatic 'eqView) rGroup)
     rspid <- spawnLocal
              $ recoverySupervisor (viewRState $(mkStatic 'rsView) rGroup)
              $ mask_ $ do
                mRCPid <- liftIO $ newEmptyMVar
                mmpid <- spawnLocal $ do
                       rcpid <- liftIO $ readMVar mRCPid
                       link rcpid
                       multimap (viewRState $(mkStatic 'multimapView) rGroup)
                rcpid <- spawnLocal (recoveryCoordinator eqpid mmpid args)
                send eqpid rcpid
                liftIO $ putMVar mRCPid rcpid
                return rcpid

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

 -- | Start the RC and EQ on the nodes in the genders file
 ignition :: (Bool, [String], [String])
          -> Process (Maybe (Bool,[NodeId],[Maybe ProcessId],[NodeId],[NodeId]))
 ignition (update, trackerstrs, nodestrs) = do
    say "Ignition!"
    disconnectAllNodeConnections
    -- XXX we are hardcoding an endpoint here, on the assumption that there is
    -- only one endpoint.
#ifdef USE_RPC
    -- TODO this is broken - needs to be fixed for USE_RPC
    let trackers = [] :: [NodeId] -- map RPC.rpcAddress trackers
    let nodes = [] :: [NodeId]
#else
    let tonid x = NodeId $ TCP.encodeEndPointAddress host port 0
          where
            sa = TCP.decodeSocketAddress x
            host = TCP.socketAddressHostName sa
            port = TCP.socketAddressServiceName sa
    let trackers = map tonid trackerstrs
    let nodes = map tonid nodestrs
#endif
    mpids <- mapM getNodeAgent trackers
    let nids = map processNodeId $ catMaybes mpids
    if update then do
      (members,newNodes) <- queryMembership nids
      added <- case members of
        m : _ -> do
          call $(functionTDict 'addNodes) m $
                 $(mkClosure 'addNodes) (newNodes,nodes,trackers)
          return True
        [] -> return False

      return $ Just (added,trackers,mpids,members,newNodes)
    else do
      cRGroup <- newRGroup $(mkStatic 'rsDict) nids
                            (RSState Nothing 0,((Nothing,[]),fromList []))
      forM_ nids $ flip spawn $
        $(mkClosure 'startRS)
          ( IgnitionArguments nodes trackers
          , cRGroup :: Closure (Process (RLogGroup HAReplicatedState))
          , Nothing :: Maybe (Replica RLogGroup)
          )
      return Nothing

  where
    queryMembership nids = do
        bs <- forM nids $ \nid ->
            call $(functionTDict 'isSelfInGroup) nid $
                 $(mkClosure 'isSelfInGroup) ()
        return $ map snd *** map snd $ partition fst $ zip bs nids
 |] ]
