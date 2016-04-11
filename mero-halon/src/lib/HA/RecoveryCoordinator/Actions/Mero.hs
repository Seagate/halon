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
  , noteToSDev
  , calculateMeroClusterStatus
  , createMeroKernelConfig
  , createMeroClientConfig
  , startMeroService
  , startNodeProcesses
  , restartNodeProcesses
  , stopNodeProcesses
  , announceMeroNodes
  , getLabeledProcesses
  , getLabeledNodeProcesses
  , m0t1fsBootLevel
  )
where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf as Conf
import HA.RecoveryCoordinator.Actions.Mero.Core
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Events.Mero
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
import Control.Monad (forM, unless)

import Data.Foldable (forM_)
import Data.Proxy
import Data.List ((\\))
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
clusterStartedBootLevel = M0.BootLevel 1

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
            phaseLog "info" $ "Still waiting for boot: " ++ show stillWaiting
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

    let ps' = map (\p -> (p, (G.connectedTo (fst p) M0.IsParentOf rg :: [M0.Service]))) procs
    phaseLog "debug" $ "Starting the procs with following services: " ++ show ps'

    unless (null procs) $ do
      msg <- StartProcesses <$> case (label, mkfs) of
              (M0.PLM0t1fs, _) -> forM procs $ (\(proc,_) -> ([M0T1FS],) <$> runConfig proc rg)
              (_, True) -> forM procs $ (\(proc,b) -> ((if b then (M0MKFS:) else id) [M0D],) <$> runConfig proc rg)
              (_, False) -> forM procs $ (\(proc,_) -> ([M0D],) <$> runConfig proc rg)
      forM_ procs $ \(p, _) -> do
        let srvs = G.connectedTo p M0.IsParentOf rg :: [M0.Service]

        applyStateChanges $ stateSet p M0.PSStarting
                          : map (\s -> stateSet s M0.SSStarting) srvs

      liftProcess $ sendChan chan msg

    return $ fst <$> procs
  where
    runConfig proc rg = case runsMgs proc rg of
      True -> syncToBS >>= \bs -> return $
                ProcessConfigLocal (M0.fid proc) (M0.r_endpoint proc) bs
      False -> return $ ProcessConfigRemote (M0.fid proc) (M0.r_endpoint proc)
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
       , G.isConnected p Is M0.PSOnline rg
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
               , G.isConnected host Has Castor.HA_M0CLIENT rg' -- which are clients
               ]
      serverHosts =
        [ host | host <- G.getResourcesOfType rg' :: [Castor.Host]
               , G.isConnected host Has Castor.HA_M0SERVER rg'
               ]

      hostsToNodes = mapMaybe (\h -> listToMaybe $ G.connectedTo h Runs rg')

      serverNodes = hostsToNodes serverHosts :: [Res.Node]
      clientNodes = hostsToNodes clientHosts :: [Res.Node]
  phaseLog "post-initial-load" $ "Sending messages about these new mero nodes: "
                              ++ show ((clientNodes, clientHosts), (serverNodes, serverHosts))
  forM_ clientNodes $ promulgateRC . NewMeroClient
  forM_ serverNodes $ promulgateRC . NewMeroServer
