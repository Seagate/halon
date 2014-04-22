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

import HA.RecoveryCoordinator.Mero (recoveryCoordinator, IgnitionArguments(..))
import HA.RecoverySupervisor ( recoverySupervisor, RSState(..) )
import HA.EventQueue ( eventQueue, EventQueue )
import HA.Multimap.Implementation ( Multimap, fromList )
import HA.Multimap.Process ( multimap )
import HA.Network.Address (readNetworkGlobalIVar, parseAddress)
import HA.NodeAgent.Lookup (lookupNodeAgent)
import HA.Replicator ( RGroup(..), RStateView(..) )
import HA.Replicator.Log ( RLogGroup )

import Control.Arrow ( first, second, (***) )
import Control.Concurrent.MVar ( newEmptyMVar, readMVar, putMVar )
import Control.Distributed.Process
import Control.Distributed.Process.Closure
    ( remotable, remotableDecl, mkStatic, mkClosure, functionTDict )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Data.Maybe (mapMaybe, catMaybes, isJust )
import qualified Mero.Genders
import Network.Transport ( endPointAddressToByteString )

import Data.ByteString as B ( ByteString, isPrefixOf, take )
import qualified Data.ByteString.Char8 as Char8 ( pack, elemIndex )
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

 isNodeInGroup :: [ByteString] -> NodeId -> Bool
 isNodeInGroup trackers n = any matchesAddress trackers
   where
     matchesAddress addr =
       B.take (maybe (error "matchAddress") id $ Char8.elemIndex ':' addr) addr
         `B.isPrefixOf` endPointAddressToByteString (nodeAddress n)

 addNodes :: ([NodeId],[String],[String]) -> Process ()
 addNodes (newNodes,nodes,trackers) = do
     disconnectAllNodeConnections
     mcRGroup <- liftIO $ readIORef globalRGroup
     case mcRGroup of
       Just cRGroup -> do
         rGroup <- unClosure cRGroup >>= id
         replicas <- setRGroupMembers rGroup newNodes $
                          $(mkClosure 'isNodeInGroup) $ map Char8.pack trackers
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
     rspid <- spawnLocal
              $ recoverySupervisor (viewRState $(mkStatic 'rsView) rGroup)
              $ mask $ const $ do
                mRCPid <- liftIO $ newEmptyMVar
                eqpid <- spawnLocal $ do
                       rcpid <- liftIO $ readMVar mRCPid
                       link rcpid
                       eventQueue (viewRState $(mkStatic 'eqView) rGroup) rcpid
                mmpid <- spawnLocal $ do
                       rcpid <- liftIO $ readMVar mRCPid
                       link rcpid
                       multimap (viewRState $(mkStatic 'multimapView) rGroup)
                rcpid <- spawnLocal (recoveryCoordinator eqpid mmpid args)
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
 ignition :: Bool
          -> Process (Maybe (Bool,[String],[Maybe ProcessId],[NodeId],[NodeId]))
 ignition update = do
     disconnectAllNodeConnections
     -- Query data from our genders file
     trackers  <- wellformQueryNodes "m0_station"
     nodes <- wellformQueryNodes "m0_all"
     network <- liftIO readNetworkGlobalIVar
     let trackerAddrs = mapMaybe parseAddress trackers
     mpids <- mapM (lookupNodeAgent network) trackerAddrs
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
                            (RSState Nothing 0,([],fromList []))
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

    wellformQueryNodes :: String -> Process [String]
    wellformQueryNodes field =
        liftIO $
        Mero.Genders.queryNodes field
        >>= mapM (\host -> do
               addr <- Mero.Genders.queryAttribute host nodeAttr
               return $ addr ++ hardwiredNA)
#ifdef USE_RPC
    nodeAttr = "m0_lnet_host"
    hardwiredNA = "@o2ib:12345:34:4"  -- hardwired part of the node agent address
#else
    nodeAttr = "m0_tcp_host"
    hardwiredNA = ":8082"
#endif

 |] ]
