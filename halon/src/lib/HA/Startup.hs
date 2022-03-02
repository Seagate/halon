{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.Startup
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Core halon node bootstrap routines.
module HA.Startup where

import           Control.Arrow ((***))
import           Control.Distributed.Process hiding (mask_, catch)
import           Control.Distributed.Process.Closure (remotable, remotableDecl, mkClosure, mkStatic)
import qualified Control.Distributed.Process.Internal.StrictMVar as StrictMVar
import           Control.Distributed.Process.Internal.Types
import           Control.Distributed.Process.Serializable (SerializableDict(..))
import           Control.Distributed.Static (closureApply)
import           Control.Monad.Catch
import           Control.Monad.Reader
import           Data.Binary (decode, encode)
import           Data.ByteString.Lazy (ByteString)
import           Data.List (partition)
import qualified Data.Map as Map
import           Data.Maybe (isJust)
import qualified HA.EQTracker.Process as EQT
import           HA.EventQueue.Process (EventQueue, eventQueueLabel, startEventQueue, emptyEventQueue)
import           HA.Logger
import           HA.Multimap (MetaInfo, defaultMetaInfo, StoreChan)
import           HA.Multimap.Implementation (Multimap, empty)
import           HA.Multimap.Process (startMultimap)
import           HA.RecoverySupervisor (recoverySupervisor)
import           HA.Replicator (RGroup(..), retryRGroup)
import           HA.Replicator.Log (RLogGroup)
import qualified HA.Storage as Storage
import qualified Network.Transport as NT
import           System.IO (hPutStrLn, stderr)
import           Text.Printf

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
                      , sp :: SendPort ProcessId
                      )
         forM_ newNodes $ \_ -> receiveChan rp
       Nothing -> return ()
     usend caller ()


 startRS :: ( Closure (Process (RLogGroup EventQueue))
            , Closure (Process (RLogGroup (MetaInfo, Multimap)))
            , Maybe (Replica RLogGroup, Replica RLogGroup)
            , Closure (ProcessId -> StoreChan -> Process ())
            , SendPort ProcessId
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
     self <- getSelfPid
     sendChan sp self
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
    selfn <- getSelfNode
    say $ printf "Ignition on %s using %s tracking stations." (show selfn) (show trackers)
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
                            (defaultMetaInfo, empty)
      (sp, rp) <- newChan

      (mrefs, srefs) <- fmap unzip . forM trackers $ \tnid -> do
        mref <- monitorNode tnid
        sref <- spawnAsync tnid $! $(mkClosure 'startRS)
          ( cEQGroup :: Closure (Process (RLogGroup EventQueue))
          , cMMGroup :: Closure (Process (RLogGroup (MetaInfo, Multimap)))
          , Nothing :: Maybe (Replica RLogGroup)
          , rcClosure
          , sp :: SendPort ProcessId
          )
        return ((tnid, mref), sref)

      -- Finish when we have no monitors (i.e. everything spawned or
      -- failed) and we're not waiting for spawned processes.
      let loop mrm _ [] | Map.null mrm = say $ "New tracking station ignited: " ++ show selfn
          loop mrm srs waits = do
            say $ printf "Waiting for %s to spawn and %s to complete startRS"
                         (show $ Map.keys mrm) (show waits)
            receiveWait [ -- startRS managed to spawn
                          matchIf (\(DidSpawn ref _) -> ref `elem` srs)
                                  (\(DidSpawn ref pid) -> do
                                    let pnid = processNodeId pid
                                    -- Only add the PID to waiting
                                    -- list if we have information
                                    -- that we are trying to spawn it.
                                    -- Even if we have a spawn ref,
                                    -- DidSpawn might have come after
                                    -- the startRS ack was processed
                                    -- and then node was removed from
                                    -- mrm.
                                    newWaits <- case Map.lookup pnid mrm of
                                      Nothing -> return waits
                                      Just n -> do
                                        unmonitor n
                                        return $ pid : waits
                                    usend pid ()
                                    loop (Map.delete pnid mrm) (filter (/= ref) srs) newWaits)
                        -- Something went wrong with node before
                        -- spawn. Notify user, but let other nodes
                        -- proceed. This is in contrast to old
                        -- behaviour where ignition would hang.
                        , matchIf (\(NodeMonitorNotification ref nid _) -> Just ref == Map.lookup nid mrm)
                                  (\(NodeMonitorNotification _ nid r) -> do
                                    say $ printf "Node %s failed during ignition: %s" (show nid) (show r)
                                    -- Keep the spawn ref around.
                                    -- Technically we could map spawn
                                    -- refs to node if we desired and
                                    -- remove it immediatelly but it's
                                    -- not necessary: we'll only leak
                                    -- SpawnRef per failed node for
                                    -- duration of ignition
                                    loop (Map.delete nid mrm) srs waits)
                        , matchChan rp $ \pid ->
                            -- Remove any PID from waiting list. Also
                            -- remove the node from node map: if we
                            -- process this before DidSpawn and don't
                            -- remove the node, we will the process to
                            -- waiting list after we have already
                            -- processed the message here and we'll
                            -- just hang forever.
                            loop (Map.delete (processNodeId pid) mrm) srs (filter (/= pid) waits)
                        ]

      loop (Map.fromList mrefs) srefs []
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
          , sp:: SendPort ProcessId
          )
    startupTrace "autoboot: waiting"
    _ <- receiveChan rp
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
