{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE TupleSections              #-}
-- |
-- Module    : HA.RecoveryCoordinator.Actions.Mero
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero actions.
module HA.RecoveryCoordinator.Actions.Mero
  ( module Conf
  , module HA.RecoveryCoordinator.Actions.Mero.Core
  , module HA.RecoveryCoordinator.Actions.Mero.Spiel
  , noteToSDev
  , calculateRunLevel
  , calculateStopLevel
  , createMeroKernelConfig
  , createMeroClientConfig
  , getClusterStatus
  , isClusterStopped
  , startMeroService
  , startNodeProcesses
  , configureMeroProcess
  , stopNodeProcesses
  , getAllProcesses
  , getLabeledProcesses
  , getLabeledNodeProcesses
  , getProcessBootLevel
  , getNodeProcesses
  , m0t1fsBootLevel
  , retriggerMeroNodeBootstrap
  )
where

import           Control.Category ((>>>))
import           Control.Distributed.Process
import           HA.Encode
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero.Conf as Conf
import           HA.RecoveryCoordinator.Actions.Mero.Core
import           HA.RecoveryCoordinator.Actions.Mero.Spiel
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Castor.Process
import           HA.RecoveryCoordinator.Events.Service
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import qualified HA.Resources as Res
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Castor as Castor
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Service
import           HA.Services.Mero
import           Mero.ConfC
import           Mero.Notification.HAState (Note(..))
import           Network.CEP
import           System.Posix.SysInfo

import           Control.Lens ((<&>))
import           Control.Monad (unless)
import           Data.Foldable (for_)
import           Data.List (sort, foldl')
import           Data.Maybe (isJust, listToMaybe, mapMaybe)
import           Data.Proxy
import           Data.UUID.V4 (nextRandom)

-- | At what boot level do we start M0t1fs processes?
m0t1fsBootLevel :: M0.BootLevel
m0t1fsBootLevel = M0.BootLevel 2

-- TODO Generalise this
-- | If the 'Note' is about an 'SDev' or 'Disk', extract the 'SDev'
-- and its 'M0.ConfObjectState'.
noteToSDev :: Note -> PhaseM LoopState l (Maybe (M0.ConfObjectState, M0.SDev))
noteToSDev (Note mfid stType)  = Conf.lookupConfObjByFid mfid >>= \case
  Just sdev -> return $ Just (stType, sdev)
  Nothing -> Conf.lookupConfObjByFid mfid >>= \case
    Just disk -> fmap (stType,) <$> Conf.lookupDiskSDev disk
    Nothing -> return Nothing

-- | Default RM service address: @":12345:41:301"@.
rmsAddress :: String
rmsAddress = ":12345:41:301"

-- | Create the necessary configuration in the resource graph to support
-- loading the Mero kernel. Currently this consists of creating a unique node
-- UUID and storing the LNet nid.
createMeroKernelConfig :: Castor.Host
                       -> String -- ^ LNet interface address
                       -> PhaseM LoopState a ()
createMeroKernelConfig host lnid = modifyLocalGraph $ \rg -> do
  uuid <- liftIO nextRandom
  return  $ G.newResource uuid
        >>> G.newResource (M0.LNid lnid)
        >>> G.connect host Has (M0.LNid lnid)
        >>> G.connect host Has uuid
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
    m0node <- case do (c :: M0.Controller) <- G.connectedFrom M0.At host rg
                      (n :: M0.Node) <- G.connectedFrom M0.IsOnHardware c rg
                      return n of
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

-- | Calculate the current run level of the cluster.
calculateRunLevel :: PhaseM LoopState l M0.BootLevel
calculateRunLevel = do
    vals <- traverse guard lvls
    return . fst . findLast $ zip lvls vals
  where
    findLast = head . reverse . takeWhile snd
    lvls = M0.BootLevel <$> [0..2]
    guard (M0.BootLevel 0) = return True
    guard (M0.BootLevel 1) = do
      -- We allow boot level 1 processes to start when at least ceil(n+1/2)
      -- confd processes have started, where n is the total number, and
      -- where we have a principal RM selected.
      prm <- getPrincipalRM
      confdprocs <- getLocalGraph <&>
        getLabeledProcesses (M0.PLBootLevel $ M0.BootLevel 0)
          (\p rg -> any
              (\s -> M0.s_type s == CST_MGS)
              [svc | svc <- G.connectedTo p M0.IsParentOf rg]
          )
      onlineProcs <- getLocalGraph <&>
        \rg -> filter (\p -> M0.getState p rg == M0.PSOnline) confdprocs
      -- The 'null confdprocs' here deserves explanation, because it
      -- shouldn't happen in a normal cluster. It just serves for test cases
      -- where there are no confd processes running. Meanwhile, it shouldn't
      -- cause any harm in real scenarios.
      return $ null confdprocs
            || (isJust prm && length onlineProcs > (length confdprocs `div` 2))
    guard (M0.BootLevel 2) = do
      -- TODO Allow boot level 2 to start up earlier
      -- We allow boot level 2 processes to start when all processes
      -- at level 1 have started.
      lvl1procs <- getLocalGraph <&>
        getLabeledProcesses (M0.PLBootLevel $ M0.BootLevel 1)
                            (const $ const True)
      onlineProcs <- getLocalGraph <&>
        \rg -> filter (\p -> M0.getState p rg == M0.PSOnline) lvl1procs
      return $ length onlineProcs == length lvl1procs
    guard (M0.BootLevel _) = return False

-- | Calculate the current stop level of the cluster. A stop level of x
-- indicates that it is valid to stop processes on that level. A stop level
-- of (-1) indicates that we may stop the halon:m0d service.
calculateStopLevel :: PhaseM LoopState l M0.BootLevel
calculateStopLevel = do
    vals <- traverse guard lvls
    return . fst . findLast $ zip lvls vals
  where
    findLast = head . reverse . takeWhile snd
    lvls = M0.BootLevel <$> reverse [(-1)..2]
    filterHA :: G.Graph -> M0.Process -> Bool
    filterHA g p = all (\srv -> M0.s_type srv /= CST_HA)
                       (G.connectedTo (p::M0.Process) M0.IsParentOf g)
      -- We allow stopping m0d when there are no running Mero processes.
    guard (M0.BootLevel (-1)) = do
      stillUnstopped <- getLocalGraph <&> \g -> filter
          ( \p -> not . null $
          [ () | M0.getState p g `elem` [ M0.PSOnline
                                        , M0.PSQuiescing
                                        , M0.PSStopping
                                        , M0.PSStarting
                                        ]
              , Just (n :: M0.Node) <- [G.connectedFrom M0.IsParentOf p g]
              , M0.getState n g /= M0.NSFailed
                && M0.getState n g /= M0.NSFailedUnrecoverable
          ]) . filter (filterHA g)
          $ M0.getM0Processes g
      return $ null stillUnstopped
    guard (M0.BootLevel 0) = do
      -- We allow stopping a process on level i if there are no running
      -- processes on level i+1
      stillUnstopped <- getLocalGraph <&>
        getLabeledProcesses (M0.PLBootLevel . M0.BootLevel $ 1)
          ( \p g -> not . null $
          [ () | M0.getState p g `elem` [ M0.PSOnline
                                        , M0.PSQuiescing
                                        , M0.PSStopping
                                        , M0.PSStarting
                                        ]
              , Just (n :: M0.Node) <- [G.connectedFrom M0.IsParentOf p g]
              , M0.getState n g /= M0.NSFailed
                && M0.getState n g /= M0.NSFailedUnrecoverable
          ] )
      return $ null stillUnstopped
    guard (M0.BootLevel 1) = do
      -- We allow stopping a process on level 1 if there are no running
      -- PLM0t1fs processes
      stillUnstopped <- getLocalGraph <&>
        getLabeledProcesses (M0.PLM0t1fs)
          ( \p g -> not . null $
          [ () | M0.getState p g `elem` [ M0.PSOnline
                                        , M0.PSQuiescing
                                        , M0.PSStopping
                                        , M0.PSStarting
                                        ]
              , Just (n :: M0.Node) <- [G.connectedFrom M0.IsParentOf p g]
              , M0.getState n g /= M0.NSFailed
                && M0.getState n g /= M0.NSFailedUnrecoverable
          ] )
      return $ null stillUnstopped
    guard (M0.BootLevel 2) = return True
    guard (M0.BootLevel _) = return False

-- | Get an aggregate cluster status report.
getClusterStatus :: G.Graph -> Maybe M0.MeroClusterState
getClusterStatus rg = let
    dispo = G.connectedTo Res.Cluster Has rg
    runLevel = G.connectedTo Res.Cluster M0.RunLevel rg
    stopLevel = G.connectedTo Res.Cluster M0.StopLevel rg
  in M0.MeroClusterState <$> dispo <*> runLevel <*> stopLevel


-- | Is the cluster completely stopped?
--
-- Cluster is completely stopped when all processes on non-failed nodes
-- are offline, failed or unknown.
isClusterStopped :: G.Graph -> Bool
isClusterStopped rg = null $
  [ p
  | Just (prof :: M0.Profile) <- [G.connectedTo Res.Cluster Has rg]
  , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
  , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
  , M0.getState node rg /= M0.NSFailed
  , (p :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
  , M0.getState node rg /= M0.NSFailedUnrecoverable
  , not . psDown $ M0.getState p rg
  , all (\srv -> M0.s_type srv /= CST_HA) $ G.connectedTo p M0.IsParentOf rg
  ]
  where
    psDown M0.PSOffline = True
    psDown (M0.PSFailed _) = True
    psDown M0.PSUnknown = True
    psDown _ = False

-- | Start all Mero processes labelled with the specified process label on
-- a given node. Returns all the processes which are being started.
startNodeProcesses :: Castor.Host
                   -> M0.ProcessLabel
                   -> PhaseM LoopState a [M0.Process]
startNodeProcesses host label = do
    rg <- getLocalGraph
    let procs =  [ p
                 | m0node <- G.connectedTo host Runs rg :: [M0.Node]
                 , p <- G.connectedTo m0node M0.IsParentOf rg
                 , G.isConnected p Has label rg
                 ]

    unless (null procs) $ do
      phaseLog "info" "Starting processes on mero node."
      phaseLog "processes" $ show (M0.fid <$> procs)
      phaseLog "process.label" $ show label
      phaseLog "process.host" $ show host
      for_ procs $ promulgateRC . ProcessStartRequest
    return procs

-- | Send a request to configure the given mero process. Constructs
-- the appropriate 'ProcessConfig' (which depends on whether the
-- process in @confd@ or not) and sends it to @halon:m0d@.
configureMeroProcess :: TypedChannel ProcessControlMsg
                     -> M0.Process
                     -> ProcessRunType
                     -> Bool
                     -> PhaseM LoopState a ()
configureMeroProcess (TypedChannel chan) p runType mkfs = do
    rg <- getLocalGraph
    conf <- if any (\s -> M0.s_type s == CST_MGS)
                 $ G.connectedTo p M0.IsParentOf rg
            then ProcessConfigLocal p <$> syncToBS
            else return $ ProcessConfigRemote p
    liftProcess . sendChan chan $ ConfigureProcess runType conf mkfs

-- | Stop the given processes.
--
-- TODO: Should get the HALON-373 treatment, nicer rule and remove/fix
-- this awful function.
stopNodeProcesses :: TypedChannel ProcessControlMsg
                  -> [M0.Process]
                  -> PhaseM LoopState a ()
stopNodeProcesses (TypedChannel chan) ps = do
   rg <- getLocalGraph
   let msg = StopProcesses $ map (go rg) ps
   phaseLog "debug" $ "Stop message: " ++ show msg
   liftProcess $ sendChan chan msg
   for_ ps $ \p -> modifyGraph
     $ \rg' -> foldl' (\g s -> M0.setState (s::M0.Service) M0.SSStopping g)
                      (M0.setState p M0.PSStopping rg')
                      (G.connectedTo p M0.IsParentOf rg')
   where
     go rg p = case G.connectedTo p Has rg of
        [M0.PLM0t1fs] -> (M0T1FS, M0.fid p)
        _             -> (M0D, M0.fid p)

-- | Get all 'M0.Process'es with the given label that also pass the
-- predicate.
getLabeledProcesses :: M0.ProcessLabel
                    -> (M0.Process -> G.Graph -> Bool)
                    -> G.Graph
                    -> [M0.Process]
getLabeledProcesses label predicate rg =
  [ proc
  | Just (prof :: M0.Profile) <- [G.connectedTo Res.Cluster Has rg]
  , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
  , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
  , (proc :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
  , G.isConnected proc Has label rg
  , predicate proc rg
  ]

-- | Get all processes on the given 'Res.Node' with the given
-- 'M0.ProcessLabel'
getLabeledNodeProcesses :: Res.Node -> M0.ProcessLabel -> G.Graph -> [M0.Process]
getLabeledNodeProcesses node label rg =
   [ p | Just host <- [G.connectedFrom Runs node rg] :: [Maybe Castor.Host]
       , m0node <- G.connectedTo host Runs rg :: [M0.Node]
       , p <- G.connectedTo m0node M0.IsParentOf rg
       , G.isConnected p Is M0.PSOnline rg
       , G.isConnected p Has label rg
   ]

-- | Fetch the boot level for the given 'Process'. This is determined as
-- follows:
--
--   * If the process has the 'PLM0t1fs' label, then the returned boot level is
--     'm0t1fsBootLevel'
--
--   * If the process has an explicit 'PLBootLevel x' label, then the returned
--     boot level is x.
--
--   * Otherwise, return 'Nothing'
--
-- If a process has multiple boot levels, then this function will return
-- the lowest (although this should not occur.)
getProcessBootLevel :: M0.Process -> G.Graph -> Maybe M0.BootLevel
getProcessBootLevel proc rg = let
    pl = G.connectedTo proc Has rg
    m0t1fs M0.PLM0t1fs = Just m0t1fsBootLevel
    m0t1fs _ = Nothing
    bl (M0.PLBootLevel x) = Just x
    bl _ = Nothing
  in case (mapMaybe m0t1fs pl, sort $ mapMaybe bl pl) of
    (x:_, _) -> Just x
    (_, x:_) -> Just x
    _ -> Nothing

-- | Get all 'M0.Process'es on the given 'Res.Node'.
getNodeProcesses :: Res.Node -> G.Graph -> [M0.Process]
getNodeProcesses node rg =
  [ p | Just host <- [G.connectedFrom Runs node rg] :: [Maybe Castor.Host]
      , m0node <- G.connectedTo host Runs rg :: [M0.Node]
      , p <- G.connectedTo m0node M0.IsParentOf rg
  ]

-- | Find every 'M0.Process' in the 'Res.Cluster'.
getAllProcesses :: G.Graph -> [M0.Process]
getAllProcesses rg =
  [ p
  | Just (prof :: M0.Profile) <- [G.connectedTo Res.Cluster Has rg]
  , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
  , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
  , (p :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
  ]

-- | Dispatch a request to start @halon:m0d@ on the given
-- 'Castor.Host'.
startMeroService :: Castor.Host -> Res.Node -> PhaseM LoopState a ()
startMeroService host node = do
  phaseLog "action" $ "Trying to start mero service on "
                    ++ show (host, node)
  rg <- getLocalGraph
  mprofile <- Conf.getProfile
  kaFreq <- getHalonVar _hv_keepalive_frequency
  kaTimeout <- getHalonVar _hv_keepalive_timeout
  mHaAddr <- Conf.lookupHostHAAddress host >>= \case
    Just addr -> return $ Just addr
    -- if there is no HA service running to give us an endpoint, pass
    -- the lnid to mkHAAddress instead of the host address: trust user
    -- setting
    Nothing -> case listToMaybe $ -- TODO: Don't ignore the other addresses?
                      G.connectedTo host Has $ rg of
      Just (M0.LNid lnid) -> return . Just $ lnid ++ haAddress
      Nothing -> return Nothing
  mapM_ promulgateRC $ do
    profile <- mprofile
    haAddr <- mHaAddr
    uuid <- G.connectedTo host Has rg
    let mconf = listToMaybe
                  [ (proc, srvHA, srvRM)
                  | m0node :: M0.Node  <- G.connectedTo host   Runs          rg
                  , proc :: M0.Process <- G.connectedTo m0node M0.IsParentOf rg
                  , srvHA  :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
                  , M0.s_type srvHA  == CST_HA
                  , srvRM  :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
                  , M0.s_type srvRM == CST_RMS
                  ]
    mconf <&> \(proc, srvHA,srvRM) ->
      let conf = MeroConf haAddr (M0.fid profile) (M0.fid proc)
                                 (M0.fid srvHA)
                                 (M0.fid srvRM)
                                 kaFreq kaTimeout
                                 (MeroKernelConf uuid)
      in encodeP $ ServiceStartRequest Start node m0d conf []


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
  case G.connectedTo Res.Cluster Has rg of
    Just M0.ONLINE -> restartMeroOnNode
    cst -> phaseLog "info"
           $ "Not trying to retrigger mero as cluster state is " ++ show cst
  where
    restartMeroOnNode = do
      rg <- getLocalGraph
      case G.connectedFrom Runs n rg of
        Nothing -> phaseLog "info" $ "Not a mero node: " ++ show n
        Just h  -> announceTheseMeroHosts [h] (\_ _ -> True)

-- | Send notifications about new mero nodes and new mero servers for
-- the given set of 'Castor.Host's.
--
-- Used during startup by 'requestClusterStart'.
announceTheseMeroHosts :: [Castor.Host] -- ^ Candidate hosts
                       -> (M0.Node -> G.Graph -> Bool) -- ^ Predicate on nodes belonging to hosts
                       -> PhaseM LoopState a ()
announceTheseMeroHosts hosts p = do
  rg' <- getLocalGraph
  let clientHosts =
        [ host | host <- hosts
               , G.isConnected host Has Castor.HA_M0CLIENT rg' -- which are clients
               ]
      serverHosts =
        [ host | host <- hosts
               , G.isConnected host Has Castor.HA_M0SERVER rg'
               ]


      -- Don't announced failed nodes
      hostsToNodes hs = [ n | h <- hs, n <- G.connectedTo h Runs rg'
                            , p n rg' ]

      serverNodes = hostsToNodes serverHosts :: [M0.Node]
      clientNodes = hostsToNodes clientHosts :: [M0.Node]
  phaseLog "post-initial-load" $ "Sending messages about these new mero nodes: "
      ++ show ((clientNodes, clientHosts), (serverNodes, serverHosts))
  for_ serverNodes $ promulgateRC . StartProcessesOnNodeRequest
  -- XXX: this is a hack, for some reason on devvm main node is not in the
  -- clients list.
  -- TODO can we remove this now? This should be marked properly.
  for_ (serverNodes++clientNodes) $ promulgateRC . StartClientsOnNodeRequest
