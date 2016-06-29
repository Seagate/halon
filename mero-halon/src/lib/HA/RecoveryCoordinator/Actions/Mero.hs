{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
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
  , noteToSDev
  , calculateMeroClusterStatus
  , clusterStartedBootLevel
  , createMeroKernelConfig
  , createMeroClientConfig
  , startMeroService
  , startNodeProcesses
  , restartNodeProcesses
  , stopNodeProcesses
  , announceMeroNodes
  , getAllProcesses
  , getLabeledProcesses
  , getLabeledNodeProcesses
  , getNodeProcesses
  , m0t1fsBootLevel
  , startMeroProcesses
  , retriggerMeroNodeBootstrap
  )
where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf as Conf
import HA.RecoveryCoordinator.Actions.Mero.Core
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Events.Mero
import HA.RecoveryCoordinator.Events.Castor.Cluster
import HA.RecoveryCoordinator.Rules.Mero.Conf (applyStateChanges)

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
import Mero.Notification.HAState (Note(..))

import Control.Category
import Control.Distributed.Process
import Control.Monad (forM, unless, when)

import Data.Foldable (for_)
import Data.Proxy
import Data.List ((\\), partition)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.UUID.V4 (nextRandom)

import Network.CEP

import System.Posix.SysInfo

import Prelude hiding ((.), id)

-- | At what boot level do we start M0t1fs processes?
m0t1fsBootLevel :: M0.BootLevel
m0t1fsBootLevel = M0.BootLevel 3

-- | At which boot level (after completion) do we consider the cluster started?
clusterStartedBootLevel :: M0.BootLevel
clusterStartedBootLevel = M0.BootLevel 2

-- TODO Generalise this
-- | If the 'Note' is about an 'SDev' or 'Disk', extract the 'SDev'
-- and its 'M0.ConfObjectState'.
noteToSDev :: Note -> PhaseM LoopState l (Maybe (M0.ConfObjectState, M0.SDev))
noteToSDev (Note mfid stType)  = Conf.lookupConfObjByFid mfid >>= \case
  Just sdev -> return $ Just (stType, sdev)
  Nothing -> Conf.lookupConfObjByFid mfid >>= \case
    Just disk -> fmap (stType,) <$> Conf.lookupDiskSDev disk
    Nothing -> return Nothing

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
    M0.MeroClusterFailed -> return M0.MeroClusterFailed
    M0.MeroClusterStarting bl@(M0.BootLevel i) -> getLocalGraph >>= \rg ->
      let
        lbl = case M0.BootLevel i of
          x | x == m0t1fsBootLevel -> M0.PLM0t1fs
          x -> M0.PLBootLevel x

        onlineOrFailed (M0.PSFailed _) = True
        onlineOrFailed st = st == M0.PSOnline

        failedProcs = getLabeledProcesses lbl (\p g -> not . null $
                      [ () | M0.PSFailed _ <- [M0.getState p g] ] ) rg

        allProcs = getLabeledProcesses lbl (\_ _ -> True) rg

        finishedProcs = getLabeledProcesses lbl
                        ( \proc g -> not . null $
                        [ () | state <- [M0.getState proc g]
                        , onlineOrFailed state
                        ] ) rg
        stillWaiting = allProcs \\ finishedProcs

        allProcsFinished = null $ getLabeledProcesses lbl
                           ( \proc g -> null $
                           [ () | state <- [M0.getState proc g]
                           , onlineOrFailed state
                           ] ) rg
      in case failedProcs of
        [] -> case allProcsFinished of
          -- All processes finished and none failed
          True -> if M0.BootLevel i == clusterStartedBootLevel
                  then return M0.MeroClusterRunning
                  else return $ M0.MeroClusterStarting $ M0.BootLevel (i+1)
          -- Not everything has finished but nothing has failed yet either
          False -> do
            phaseLog "info" $ "Still waiting for boot: " ++ show (map M0.fid stillWaiting)
            return $ M0.MeroClusterStarting bl
        -- Some process failed, bail
        _:_ -> return M0.MeroClusterFailed
    M0.MeroClusterStopping bl@(M0.BootLevel i) -> getLocalGraph >>= \rg ->
      let
        lbl = case M0.BootLevel i of
          x | x == m0t1fsBootLevel -> M0.PLM0t1fs
          x -> M0.PLBootLevel x

        stillUnstopped = getLabeledProcesses lbl
                         ( \proc g -> not . null $
                         [ () | state <- G.connectedTo proc Is g
                              , state `elem` [M0.PSOnline, M0.PSStopping, M0.PSStarting]
                         ] ) rg
      in if null $ stillUnstopped
      then case i of
        0 -> return M0.MeroClusterStopped
        _ -> return $ M0.MeroClusterStopping $ M0.BootLevel (i-1)
      else do
        phaseLog "info" $ "Still waiting for following processes to stop: "
                       ++ show (M0.fid <$> stillUnstopped)
        return $ M0.MeroClusterStopping bl

-- | Start all Mero processes labelled with the specified process label on
--   a given node. Returns all the processes which are being started.
startNodeProcesses :: Castor.Host
                   -> TypedChannel ProcessControlMsg
                   -> M0.ProcessLabel
                   -> Bool -- ^ Run mkfs? Ignored for m0t1fs processes.
                   -> PhaseM LoopState a [M0.Process]
startNodeProcesses host chan label mkfs = do
    rg <- getLocalGraph
    let allProcs =  [ p
                    | m0node <- G.connectedTo host Runs rg :: [M0.Node]
                    , p <- G.connectedTo m0node M0.IsParentOf rg
                    , G.isConnected p Has label rg
                    ]
    if null allProcs
    then phaseLog "action" $ "No services with label " ++ show label ++ " on host " ++ show host
    else phaseLog "action" $ "Starting services with label " ++ show label ++ "on host " ++ show host

    -- If RC has restarted the bootstrap rule, some processes may have
    -- already been online: we don't want to try and start those
    -- processes again (so we filter them here) and we want the
    -- bootstrap to proceed (so we notify ONLINE about those processes
    -- here: this will cause internal notification about process state
    -- to go out which will be picked up by adjustClusterState which
    -- should release the barrier even if all the processes are
    -- already started)
    let (onlineProcs, procs) = partition (\p -> M0.getState p rg == M0.PSOnline) allProcs
    applyStateChanges $ map (\p -> stateSet p M0.PSOnline) onlineProcs

    startMeroProcesses chan procs label mkfs
    return procs

-- | Start given mero processes.
startMeroProcesses :: TypedChannel ProcessControlMsg -- ^ halon:m0d channel.
                   -> [M0.Process]
                   -> M0.ProcessLabel
                   -> Bool -- ^ Run mkfs? Ignored for m0t1fs processes
                   -> PhaseM LoopState a ()
startMeroProcesses (TypedChannel chan) procs' label mkfs = do
    rg <- getLocalGraph
    let procs = map (\p -> (p, not $ G.isConnected p Is M0.ProcessBootstrapped rg)) procs'
    unless (null procs) $ do
      msg <- StartProcesses <$> case (label, mkfs) of
              (M0.PLM0t1fs, _) -> forM procs (\(proc,_) -> ([M0T1FS],) <$> runConfig proc rg)
              (_, True) -> forM procs (\(proc,b) -> ((if b then (M0MKFS:) else id) [M0D],) <$> runConfig proc rg)
              (_, False) -> forM procs (\(proc,_) -> ([M0D],) <$> runConfig proc rg)
      phaseLog "debug" $ "starting mero processes: " ++ show (fmap (M0.fid.fst) procs)

      -- Hack, see ruleProcessOnline
      for_ procs $ \(p, b) -> when (mkfs && b) $ do
        modifyGraph $ G.connectUniqueFrom p Has (M0.PID (-1))

      liftProcess $ sendChan chan msg
      for_ procs' $ \p -> modifyGraph
        $ \rg' -> foldr (\s -> M0.setState (s::M0.Service) M0.SSStarting)
                        (M0.setState p M0.PSStarting rg')
                        (G.connectedTo p M0.IsParentOf rg')
  where
    runConfig proc rg
      | runsMgs proc rg = syncToBS >>= \bs -> return $
         ProcessConfigLocal (M0.fid proc) (M0.r_endpoint proc) bs
      | otherwise = return $
         ProcessConfigRemote (M0.fid proc) (M0.r_endpoint proc)
    runsMgs proc rg =
      not . null $ [ () | M0.Service{ M0.s_type = CST_MGS }
                          <- G.connectedTo proc M0.IsParentOf rg ]

restartNodeProcesses :: TypedChannel ProcessControlMsg
                     -> [M0.Process]
                     -> PhaseM LoopState a ()
restartNodeProcesses (TypedChannel chan) ps = do
   rg <- getLocalGraph
   let msg = RestartProcesses $ map (go rg) ps
   liftProcess $ sendChan chan msg
   where
     go rg p = case G.connectedTo p Has rg of
        [M0.PLM0t1fs] -> ([M0T1FS], ProcessConfigRemote (M0.fid p) (M0.r_endpoint p))
        _             -> ([M0D], ProcessConfigRemote (M0.fid p) (M0.r_endpoint p))

stopNodeProcesses :: TypedChannel ProcessControlMsg
                  -> [M0.Process]
                  -> PhaseM LoopState a ()
stopNodeProcesses (TypedChannel chan) ps = do
   rg <- getLocalGraph
   let msg = StopProcesses $ map (go rg) ps
   liftProcess $ sendChan chan msg
   for_ ps $ \p -> modifyGraph
     $ \rg' -> foldr (\s -> M0.setState (s::M0.Service) M0.SSStopping)
                    (G.connectUniqueFrom p Is M0.PSStopping rg')
                    (G.connectedTo p M0.IsParentOf rg')
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
       , G.isConnected p Is M0.PSOnline rg
       , G.isConnected p Has label rg
   ]

getNodeProcesses :: Res.Node -> G.Graph -> [M0.Process]
getNodeProcesses node rg =
  [ p | host <- G.connectedFrom Runs node rg :: [Castor.Host]
      , m0node <- G.connectedTo host Runs rg :: [M0.Node]
      , p <- G.connectedTo m0node M0.IsParentOf rg
  ]

-- | Find every 'M0.Process' in the 'Res.Cluster'.
getAllProcesses :: G.Graph -> [M0.Process]
getAllProcesses rg =
  [ p
  | (prof :: M0.Profile) <- G.connectedTo Res.Cluster Has rg
  , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
  , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
  , (p :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
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
    let mconf = listToMaybe
                  [ conf
                  | m0node :: M0.Node  <- G.connectedTo host   Runs          rg
                  , proc :: M0.Process <- G.connectedTo m0node M0.IsParentOf rg
                  , srv  :: M0.Service <- G.connectedTo proc   M0.IsParentOf rg
                  , M0.s_type srv  == CST_HA
                  , let conf = MeroConf haAddr (M0.fid profile)
                                               (M0.fid proc)
                                               (MeroKernelConf uuid)
                  ]
    (\conf -> encodeP $ ServiceStartRequest Start node m0d conf []) <$> mconf

-- | It may happen that a node reboots (either through halon or
-- through external means) during cluster's lifetime. The below
-- function re-triggers the mero part of the bootstrap on the node.
--
-- Any halon services that need restarting will have been triggered in
-- @node-up@ rule. @halon:m0d@ is excluded from that as that
-- particular service is going to be restarted as part of the node
-- bootstrap.
retriggerMeroNodeBootstrap :: M0.Node -> PhaseM LoopState a ()
retriggerMeroNodeBootstrap n = do
  rg <- getLocalGraph
  case listToMaybe $ G.connectedTo Res.Cluster Has rg of
    Just M0.MeroClusterRunning -> restartMeroOnNode
    Just M0.MeroClusterStarting{} -> restartMeroOnNode
    cst -> phaseLog "info"
           $ "Not trying to retrigger mero as cluster state is " ++ show cst
  where
    restartMeroOnNode = do
      rg <- getLocalGraph
      case G.connectedFrom Runs n rg of
        [] -> phaseLog "info" $ "Not a mero node: " ++ show n
        h : _ -> announceTheseMeroHosts [h]

-- | Send notifications about new mero nodes and new mero servers for
-- the given set of 'Castor.Host's.
announceTheseMeroHosts :: [Castor.Host] -> PhaseM LoopState a ()
announceTheseMeroHosts hosts = do
  rg' <- getLocalGraph
  let clientHosts =
        [ host | host <- hosts
               , G.isConnected host Has Castor.HA_M0CLIENT rg' -- which are clients
               ]
      serverHosts =
        [ host | host <- hosts
               , G.isConnected host Has Castor.HA_M0SERVER rg'
               ]

      hostsToNodes = mapMaybe (\h -> listToMaybe $ G.connectedTo h Runs rg')

      serverNodes = hostsToNodes serverHosts :: [M0.Node]
      clientNodes = hostsToNodes clientHosts :: [M0.Node]
  phaseLog "post-initial-load" $ "Sending messages about these new mero nodes: "
      ++ show ((clientNodes, clientHosts), (serverNodes, serverHosts))
  for_ serverNodes $ promulgateRC . StartProcessesOnNodeRequest
  -- XXX: this is a hack, for some reason on devvm main node is not in the
  -- clients list.
  for_ (serverNodes++clientNodes) $ promulgateRC . StartClientsOnNodeRequest


-- | Send notifications about new mero nodes and new mero servers for
-- every 'Castor.Host' in RG.
announceMeroNodes :: PhaseM LoopState a ()
announceMeroNodes = do
  rg' <- getLocalGraph
  announceTheseMeroHosts $ G.connectedTo Res.Cluster Has rg'
