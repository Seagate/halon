{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE TupleSections              #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.RecoveryCoordinator.Actions.Mero
  ( module Conf
  , module HA.RecoveryCoordinator.Actions.Mero.Core
  , module HA.RecoveryCoordinator.Actions.Mero.Spiel
  , notifyDriveStateChange
  , updateDriveState
  , updateDriveStatesFromSet
  , noteToSDev
  , calculateMeroClusterStatus
  , createMeroKernelConfig
  , createMeroClientConfig
  , startMeroService
  , startNodeProcesses
  , stopNodeProcesses
  , announceMeroNodes
  , getLabeledProcesses
  , getLabeledNodeProcesses
  )
where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf as Conf
import HA.RecoveryCoordinator.Actions.Mero.Core
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Events.Mero

import HA.Resources.Castor (Is(..))
import HA.Resources (Has(..))
import qualified HA.Resources as Res
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Castor as Castor
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Service
import HA.Services.Mero

import Mero.ConfC
import Mero.Notification (Set(..))
import Mero.Notification.HAState (Note(..))

import Control.Category
import Control.Distributed.Process
import Control.Monad (forM, unless)

import Data.Foldable (forM_, traverse_)
import Data.Proxy
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.UUID.V4 (nextRandom)

import Network.CEP

import System.Posix.SysInfo

import Prelude hiding ((.), id)

-- | At what boot level do we start M0t1fs processes?
m0t1fsBootLevel :: M0.BootLevel
m0t1fsBootLevel = M0.BootLevel 3

-- | At which boot level (after completion) do we consider the cluster started?
clusterStartedBootLevel :: M0.BootLevel
clusterStartedBootLevel = M0.BootLevel 3


-- TODO Generalise this
-- | If the 'Note' is about an 'SDev' or 'Disk', extract the 'SDev'
-- and its 'M0.ConfObjectState'.
noteToSDev :: Note -> PhaseM LoopState l (Maybe (M0.ConfObjectState, M0.SDev))
noteToSDev (Note mfid stType)  = Conf.lookupConfObjByFid mfid >>= \case
  Just sdev -> return $ Just (stType, sdev)
  Nothing -> Conf.lookupConfObjByFid mfid >>= \case
    Just disk -> fmap (stType,) <$> Conf.lookupDiskSDev disk
    Nothing -> return Nothing

-- | Extract information about drives from the given set of
-- notifications and update the state in RG accordingly.
updateDriveStatesFromSet :: Set -> PhaseM LoopState l ()
updateDriveStatesFromSet (Set ns) = catMaybes <$> mapM noteToSDev ns
                             >>= mapM_ (\(typ, sd) -> updateDriveState sd typ)

-- | Notify ourselves about a state change of the 'M0.SDev'.
--
-- Internally, build a note 'Set' and pass it to all registered
-- stateChangeHandlers.
--
-- It's important to understand that this function does not replace
-- 'updateDriveState' which performs the actual update.
notifyDriveStateChange :: M0.SDev -> M0.ConfObjectState -> PhaseM LoopState l ()
notifyDriveStateChange m0sdev st = do
    stateChangeHandlers <- lsStateChangeHandlers <$> get Global
    sequence_ $ ($ ns) <$> stateChangeHandlers
 where
   ns = Set [Note (M0.fid m0sdev) st]

updateDriveState :: M0.SDev -- ^ Drive to update state
                 -> M0.ConfObjectState -- ^ State to update to
                 -> PhaseM LoopState l ()

-- | For transient failures, we may need to create a new pool version.
updateDriveState m0sdev M0.M0_NC_TRANSIENT = do
  -- Update state in RG
  modifyGraph $ G.connectUniqueFrom m0sdev Is M0.M0_NC_TRANSIENT
  graph <- getLocalGraph
  let m0disks = G.connectedTo m0sdev M0.IsOnHardware graph :: [M0.Disk]
  traverse_ (\m0disk -> modifyGraph $ G.connectUniqueFrom m0disk Is M0.M0_NC_TRANSIENT)
            m0disks
  syncGraph (return ()) -- possibly we need to wait here, but I see no good
                        -- reason for that.
  -- If using dynamic failure sets, generate failure set
  sgraph <- getLocalGraph
  mstrategy <- getCurrentStrategy
  forM_ mstrategy $ \strategy ->
    forM_ (onFailure strategy sgraph) $ \graph' -> do
      putLocalGraph graph'
      syncAction Nothing M0.SyncToConfdServersInRG
  -- Notify Mero
  let m0objs = M0.AnyConfObj <$> m0disks
  notifyMero (M0.AnyConfObj m0sdev:m0objs) M0.M0_NC_TRANSIENT

-- | For all other states, we simply update in the RG and notify Mero.
updateDriveState m0sdev x = do
  phaseLog "rg" $ "Updating status of SDev "
                ++ show m0sdev
                ++ " to "
                ++ show x
  -- Update state in RG
  modifyGraph $ G.connectUniqueFrom m0sdev Is x
  graph <- getLocalGraph
  let m0disks = G.connectedTo m0sdev M0.IsOnHardware graph :: [M0.Disk]
  traverse_ (\m0disk -> modifyGraph $ G.connectUniqueFrom m0disk Is x) m0disks
  -- Quite possibly we need to wait for synchronization result here, because
  -- otherwise we may notifyMero multiple times (if consesus will be lost).
  -- however in opposite case we may never notify mero if RC will die after
  -- sync, but before it notified mero.
  syncGraph (return ())
  -- Notify Mero
  let m0objs = M0.AnyConfObj <$> m0disks
  notifyMero (M0.AnyConfObj m0sdev:m0objs) x

-- | RMS service address.
rmsAddress :: String
rmsAddress = ":12345:41:301"

-- | Create the necessary configuration in the resource graph to support
--   loading the Mero kernel. Currently this consists of creating a unique node
--   UUID and storing the LNet nid.
createMeroKernelConfig :: Castor.Host
                       -> String -- ^ LNet interface address
                       -> PhaseM LoopState a ()
createMeroKernelConfig host lnid = modifyLocalGraph $ \rg -> do
  uuid <- liftIO nextRandom
  return  $ G.newResource uuid
        >>> G.newResource (M0.LNid lnid)
        >>> G.connect host Has (M0.LNid lnid)
        >>> G.connectUnique host Has uuid
          $ rg

-- | Create relevant configuration for a mero client in the RG.
--
-- If the 'Host' already contains all the required information, no new
-- information will be added.
createMeroClientConfig :: M0.Filesystem
                        -> Castor.Host
                        -> HostHardwareInfo
                        -> PhaseM LoopState a ()
createMeroClientConfig fs host (HostHardwareInfo memsize cpucnt nid) = do
  createMeroKernelConfig host nid
  modifyLocalGraph $ \rg -> do
    -- Check if node is already defined in RG
    m0node <- case listToMaybe [ n | (c :: M0.Controller) <- G.connectedFrom M0.At host rg
                                   , (n :: M0.Node) <- G.connectedFrom M0.IsOnHardware c rg
                                   ] of
      Just nd -> return nd
      Nothing -> M0.Node <$> newFidRC (Proxy :: Proxy M0.Node)
    -- Check if process is already defined in RG
    let mprocess = listToMaybe
          $ filter (\(M0.Process _ _ _ _ _ _ a) -> a == nid ++ rmsAddress)
          $ G.connectedTo m0node M0.IsParentOf rg
    process <- case mprocess of
      Just process -> return process
      Nothing -> M0.Process <$> newFidRC (Proxy :: Proxy M0.Process)
                            <*> pure memsize
                            <*> pure memsize
                            <*> pure memsize
                            <*> pure memsize
                            <*> pure (bitmapFromArray (replicate cpucnt True))
                            <*> pure (nid ++ rmsAddress)
    -- Check if RMS service is already defined in RG
    let mrmsService = listToMaybe
          $ filter (\(M0.Service _ x _ _) -> x == CST_RMS)
          $ G.connectedTo process M0.IsParentOf rg
    rmsService <- case mrmsService of
      Just service -> return service
      Nothing -> M0.Service <$> newFidRC (Proxy :: Proxy M0.Service)
                            <*> pure CST_RMS
                            <*> pure [nid ++ rmsAddress]
                            <*> pure SPUnused
    -- Check if HA service is already defined in RG
    let mhaService = listToMaybe
          $ filter (\(M0.Service _ x _ _) -> x == CST_HA)
          $ G.connectedTo process M0.IsParentOf rg
    haService <- case mhaService of
      Just service -> return service
      Nothing -> M0.Service <$> newFidRC (Proxy :: Proxy M0.Service)
                            <*> pure CST_HA
                            <*> pure [nid ++ haAddress]
                            <*> pure SPUnused
    -- Create graph
    let rg' = G.newResource m0node
          >>> G.newResource process
          >>> G.newResource rmsService
          >>> G.newResource haService
          >>> G.connect m0node M0.IsParentOf process
          >>> G.connect process M0.IsParentOf rmsService
          >>> G.connect process M0.IsParentOf haService
          >>> G.connect process Has M0.PLM0t1fs
          >>> G.connect process Is M0.PSUnknown
          >>> G.connect fs M0.IsParentOf m0node
          >>> G.connect host Has Castor.HA_M0CLIENT
          >>> G.connect host Runs m0node
            $ rg
    return rg'

-- | Look at the current cluster status and current local status and
--   calculate whether we should move to a new status.
calculateMeroClusterStatus :: PhaseM LoopState l M0.MeroClusterState
calculateMeroClusterStatus = do
  -- Currently recorded status in the graph
  recordedState <- fromMaybe M0.MeroClusterStopped . listToMaybe
                    . G.connectedTo Res.Cluster Has <$> getLocalGraph
  case recordedState of
    M0.MeroClusterStopped -> return M0.MeroClusterStopped
    M0.MeroClusterRunning -> return M0.MeroClusterRunning
    M0.MeroClusterStarting bl@(M0.BootLevel i) -> getLocalGraph >>= \rg ->
      let
        lbl = case M0.BootLevel i of
          x | x == m0t1fsBootLevel -> M0.PLM0t1fs
          x -> M0.PLBootLevel x
      in if null $ getLabeledProcesses lbl
                  ( \proc g -> null $
                    [ () | state <- G.connectedTo proc Is g
                    , state == M0.PSOnline
                    ] ) rg
      then case i of
        x | M0.BootLevel x == clusterStartedBootLevel -> return M0.MeroClusterRunning
        _ -> return $ M0.MeroClusterStarting $ M0.BootLevel (i+1)
      else return $ M0.MeroClusterStarting bl
    M0.MeroClusterStopping bl@(M0.BootLevel i) -> getLocalGraph >>= \rg ->
      let
        lbl = case M0.BootLevel i of
          x | x == m0t1fsBootLevel -> M0.PLM0t1fs
          x -> M0.PLBootLevel x
      in if null $ getLabeledProcesses lbl
                ( \proc g -> not . null $
                  [ () | state <- G.connectedTo proc Is g
                  , state `elem` [M0.PSOnline, M0.PSStarting, M0.PSStopping]
                  ] ) rg
      then case i of
        0 -> return M0.MeroClusterStopped
        _ -> return $ M0.MeroClusterStopping $ M0.BootLevel (i-1)
      else return $ M0.MeroClusterStopping bl

-- | Start all Mero processes labelled with the specified process label on
--   a given node. Returns all the processes which are being started.
startNodeProcesses :: Castor.Host
                   -> (TypedChannel ProcessControlMsg)
                   -> M0.ProcessLabel
                   -> Bool -- ^ Run mkfs? Ignored for m0t1fs processes.
                   -> PhaseM LoopState a [M0.Process]
startNodeProcesses host (TypedChannel chan) label mkfs = do
    phaseLog "action" $ "Trying to start all processes with label "
                      ++ show label
                      ++ " on host "
                      ++ show host
    rg <- getLocalGraph
    let procs =  [ (p :: M0.Process, b :: Bool)
                 | m0node <- G.connectedTo host Runs rg :: [M0.Node]
                 , p <- G.connectedTo m0node M0.IsParentOf rg
                 , G.isConnected p Has label rg
                 , let b = not $ G.isConnected p Is M0.ProcessBootstrapped rg
                 ]
    phaseLog "processes" $ show (fmap (M0.fid.fst) procs)
    unless (null procs) $ do
      msg <- StartProcesses <$> case (label, mkfs) of
              (M0.PLM0t1fs, _) -> forM procs $ (\(proc,_) -> ([M0T1FS],) <$> runConfig proc rg)
              (_, True) -> forM procs $ (\(proc,b) -> ((if b then (M0MKFS:) else id) [M0D],) <$> runConfig proc rg)
              (_, False) -> forM procs $ (\(proc,_) -> ([M0D],) <$> runConfig proc rg)
      liftProcess $ sendChan chan msg
      forM_ procs $ \(p, _) -> modifyGraph
        $ G.connectUniqueFrom p Is M0.PSStarting
    return $ fst <$> procs
  where
    runConfig proc rg = case runsMgs proc rg of
      True -> syncToBS >>= \bs -> return $
                ProcessConfigLocal (M0.fid proc) (M0.r_endpoint proc) bs
      False -> return $ ProcessConfigRemote (M0.fid proc) (M0.r_endpoint proc)
    runsMgs proc rg =
      not . null $ [ () | M0.Service{ M0.s_type = CST_MGS }
                          <- G.connectedTo proc M0.IsParentOf rg
                   ]

stopNodeProcesses :: Castor.Host
                  -> TypedChannel ProcessControlMsg
                  -> [M0.Process]
                  -> PhaseM LoopState a ()
stopNodeProcesses _ (TypedChannel chan) ps = do
   rg <- getLocalGraph
   let msg = StopProcesses $ map (go rg) ps
   liftProcess $ sendChan chan msg
   forM_ ps $ \p -> modifyGraph
     $ G.connectUniqueFrom p Is M0.PSStopping
   where
     go rg p = case G.connectedTo p Has rg of
        [M0.PLM0t1fs] -> ([M0T1FS], ProcessConfigRemote (M0.fid p) (M0.r_endpoint p))
        _             -> ([M0D], ProcessConfigRemote (M0.fid p) (M0.r_endpoint p))

getLabeledProcesses :: M0.ProcessLabel
                    -> (M0.Process -> G.Graph -> Bool)
                    -> G.Graph
                    -> [M0.Process]
getLabeledProcesses label predicate rg =
  [ proc
  | (prof :: M0.Profile) <- G.connectedTo Res.Cluster Has rg
  , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
  , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
  , (proc :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
  , G.isConnected proc Has label rg
  , predicate proc rg
  ]

getLabeledNodeProcesses :: Res.Node -> M0.ProcessLabel -> G.Graph -> [M0.Process]
getLabeledNodeProcesses node label rg =
   [ p | host <- G.connectedFrom Runs node rg :: [Castor.Host]
       , m0node <- G.connectedTo host Runs rg :: [M0.Node]
       , p <- G.connectedTo m0node M0.IsParentOf rg
       , G.isConnected p Is M0.M0_NC_ONLINE rg
       , G.isConnected p Has label rg
   ]

startMeroService :: Castor.Host -> Res.Node -> PhaseM LoopState a ()
startMeroService host node = do
  phaseLog "action" $ "Trying to start mero service on "
                    ++ show (host, node)
  rg <- getLocalGraph
  mprofile <- Conf.getProfile
  mHaAddr <- Conf.lookupHostHAAddress host >>= \case
    Just addr -> return $ Just addr
    -- if there is no HA service running to give us an endpoint, pass
    -- the lnid to mkHAAddress instead of the host address: trust user
    -- setting
    Nothing -> case listToMaybe . G.connectedTo host Has $ rg of
      Just (M0.LNid lnid) -> return . Just $ lnid ++ haAddress
      Nothing -> return Nothing
  mapM_ promulgateRC $ do
    profile <- mprofile
    haAddr <- mHaAddr
    uuid <- listToMaybe $ G.connectedTo host Has rg
    let conf = MeroConf haAddr (fidToStr $ M0.fid profile)
                (MeroKernelConf uuid)
    return $ encodeP $ ServiceStartRequest Start node m0d conf []

-- | Send notifications about new mero nodes and new mero servers.
announceMeroNodes :: PhaseM LoopState a ()
announceMeroNodes = do
  rg' <- getLocalGraph
  let clientHosts =
        [ host | host <- G.getResourcesOfType rg'    :: [Castor.Host] -- all hosts
               , not  $ G.isConnected host Has Castor.HA_M0CLIENT rg' -- and not already a client
               , not  $ G.isConnected host Has Castor.HA_M0SERVER rg' -- and not already a server
               ]

      hostsToNodes = mapMaybe (\h -> listToMaybe $ G.connectedTo h Runs rg')
      serverHosts = [ host | host <- G.getResourcesOfType rg' :: [Castor.Host]
                           , G.isConnected host Has Castor.HA_M0SERVER rg' ]

      serverNodes = hostsToNodes serverHosts :: [Res.Node]
      clientNodes = hostsToNodes clientHosts :: [Res.Node]
  phaseLog "post-initial-load" $ "Sending messages about these new mero nodes: "
                              ++ show ((clientNodes, clientHosts), (serverNodes, serverHosts))
  forM_ clientNodes $ promulgateRC . NewMeroClient
  forM_ serverNodes $ promulgateRC . NewMeroServer
