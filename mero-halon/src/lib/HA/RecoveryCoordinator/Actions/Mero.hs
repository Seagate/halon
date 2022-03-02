{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TupleSections    #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Module    : HA.RecoveryCoordinator.Actions.Mero
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Mero actions.
module HA.RecoveryCoordinator.Actions.Mero
  ( module HA.RecoveryCoordinator.Mero.Actions.Conf
  , module HA.RecoveryCoordinator.Mero.Actions.Core
  , module HA.RecoveryCoordinator.Mero.Actions.Initial
  , module HA.RecoveryCoordinator.Mero.Actions.Spiel
  , noteToSDev
  , calculateRunLevel
  , calculateStopLevel
  , createMeroKernelConfig
  , createMeroClientConfig
  , getClusterStatus
  , isClusterStopped
  , startMeroService
  , configureMeroProcess
  , m0t1fsBootLevel
  , retriggerMeroNodeBootstrap
  , getRunningMeroInterface
  )
where

import           Control.Category ((>>>))
import           Control.Distributed.Process
import           Control.Lens ((<&>))
import           Data.Foldable (for_)
import           Data.Function ((&))
import           Data.Maybe (isJust, listToMaybe)
import           Data.Proxy
import qualified Data.Text as T
import qualified Data.UUID as UUID
import           Data.UUID.V4 (nextRandom)
import           HA.Encode
import qualified HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
import           HA.RecoveryCoordinator.Castor.Node.Events
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.Mero.Actions.Conf
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Actions.Initial
import           HA.RecoveryCoordinator.Mero.Actions.Spiel
import           HA.RecoveryCoordinator.Mero.State (applyStateChanges, stateSet)
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.Service.Events
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources as R (Node)
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Service
import           HA.Service.Interface
import           HA.Services.Mero
import           Mero.ConfC
  ( bitmapFromArray
  , ServiceType(CST_CAS,CST_CONFD,CST_HA,CST_RMS)
  )
import           Mero.Lnet
import           Mero.Notification.HAState (Note(..))
import           Network.CEP

-- | At what boot level do we start M0t1fs processes?
m0t1fsBootLevel :: M0.BootLevel
m0t1fsBootLevel = M0.BootLevel 2

-- TODO Generalise this
-- | If the 'Note' is about an 'SDev' or 'Disk', extract the 'SDev'
-- and its 'M0.ConfObjectState'.
noteToSDev :: Note -> PhaseM RC l (Maybe (M0.ConfObjectState, M0.SDev))
noteToSDev (Note mfid stType) = lookupConfObjByFid mfid >>= \case
  Just sdev -> return $ Just (stType, sdev)
  Nothing -> lookupConfObjByFid mfid >>= \case
    Just disk -> fmap (stType,) <$> Drive.lookupDiskSDev disk
    Nothing -> return Nothing

-- | Default RM service address: @":12345:41:301"@.
rmsAddress :: LNid -> Endpoint
rmsAddress lnid = Endpoint {
    network_id = lnid
  , process_id = 12345
  , portal_number = 41
  , transfer_machine_id = 301
  }

-- | Create the necessary configuration in the resource graph to support
-- loading the Mero kernel. Currently this consists of creating a unique node
-- UUID and storing the LNet nid.
createMeroKernelConfig :: Cas.Host
                       -> LNid -- ^ LNet interface address
                       -> PhaseM RC a ()
createMeroKernelConfig host lnid = do
  uuid <- liftIO nextRandom
  modifyGraph $ G.connect host Has uuid . G.connect host Has (M0.LNid lnid)

-- | Create relevant configuration for a mero client in the RG.
--
-- If the 'Host' already contains all the required information, no new
-- information will be added.
createMeroClientConfig :: Cas.Host
                       -> M0.HostHardwareInfo
                       -> PhaseM RC a ()
createMeroClientConfig host (M0.HostHardwareInfo memsize cpucnt lnid) = do
  createMeroKernelConfig host lnid
  modifyGraphM $ \rg -> do
    -- Check if node is already defined in RG
    m0node <- case do c :: M0.Controller <- G.connectedFrom M0.At host rg
                      n :: M0.Node <- G.connectedFrom M0.IsOnHardware c rg
                      return n of
      Just nd -> return nd
      Nothing -> M0.Node <$> newFidRC (Proxy :: Proxy M0.Node)
    -- Check if process is already defined in RG
    let mprocess = listToMaybe
          . filter (\(M0.Process _ _ _ _ _ _ a) -> a == rmsAddress lnid)
          $ G.connectedTo m0node M0.IsParentOf rg
    process <- case mprocess of
      Just process -> return process
      Nothing -> M0.Process <$> newFidRC (Proxy :: Proxy M0.Process)
                            <*> pure memsize
                            <*> pure memsize
                            <*> pure memsize
                            <*> pure memsize
                            <*> pure (bitmapFromArray (replicate cpucnt True))
                            <*> pure (rmsAddress lnid)
    -- Check if RMS service is already defined in RG
    let mrmsService = listToMaybe
          . filter (\(M0.Service _ x _) -> x == CST_RMS)
          $ G.connectedTo process M0.IsParentOf rg
    rmsService <- case mrmsService of
      Just service -> return service
      Nothing -> M0.Service <$> newFidRC (Proxy :: Proxy M0.Service)
                            <*> pure CST_RMS
                            <*> pure [rmsAddress lnid]
    -- Check if HA service is already defined in RG
    let mhaService = listToMaybe
          . filter (\(M0.Service _ x _) -> x == CST_HA)
          $ G.connectedTo process M0.IsParentOf rg
    haService <- case mhaService of
      Just service -> return service
      Nothing -> M0.Service <$> newFidRC (Proxy :: Proxy M0.Service)
                            <*> pure CST_HA
                            <*> pure [haAddress lnid]
    -- Create graph
    let rg' = G.connect m0node M0.IsParentOf process
          >>> G.connect process M0.IsParentOf rmsService
          >>> G.connect process M0.IsParentOf haService
          >>> G.connect process Has CI.PLM0t1fs
          >>> G.connect process Is M0.PSUnknown
          >>> G.connect (M0.getM0Root rg) M0.IsParentOf m0node
          >>> G.connect host Runs m0node
            $ rg
    return rg'

-- | Calculate the current run level of the cluster.
calculateRunLevel :: PhaseM RC l M0.BootLevel
calculateRunLevel = do
    vals <- traverse guard lvls
    return . fst . findLast $ zip lvls vals
  where
    findLast = head . reverse . takeWhile snd
    lvls = M0.BootLevel <$> [0..3]
    guard (M0.BootLevel 0) = return True
    guard (M0.BootLevel 1) = do
      -- We allow boot level 1 processes to start when at least ceil(n+1/2)
      -- confd processes have started, where n is the total number, and
      -- where we have a principal RM selected.
      prm <- getPrincipalRM
      confdprocs <- getGraph <&> \rg ->
        Process.getTyped (CI.PLM0d 0) rg & filter
          (\p -> any
              (\s -> M0.s_type s == CST_CONFD)
              (G.connectedTo p M0.IsParentOf rg)
          )
      onlineProcs <- getGraph <&>
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
      lvl1procs <- getGraph <&>
        Process.getTyped (CI.PLM0d 1)
      onlineProcs <- getGraph <&>
        \rg -> filter (\p -> M0.getState p rg == M0.PSOnline) lvl1procs
      return $ length onlineProcs == length lvl1procs
    guard (M0.BootLevel 3) = do
      -- Boot level 3 may start once all CAS services have started.
      casProcs <- getGraph <&>
        Process.getAllHostingService CST_CAS
      onlineProcs <- getGraph <&>
        \rg -> filter (\p -> M0.getState p rg == M0.PSOnline) casProcs
      return $ length onlineProcs == length casProcs
    guard (M0.BootLevel _) = return False

-- | Calculate the current stop level of the cluster. A stop level of x
-- indicates that it is valid to stop processes on that level. A stop level
-- of (-1) indicates that we may stop the halon:m0d service.
calculateStopLevel :: PhaseM RC l M0.BootLevel
calculateStopLevel = do
    vals <- traverse guard lvls
    return . fst . findLast $ zip lvls vals
  where
    findLast = head . reverse . takeWhile snd
    lvls = M0.BootLevel <$> reverse [(-1)..3]

    filterHA :: G.Graph -> M0.Process -> Bool
    filterHA g p = all (\srv -> M0.s_type srv /= CST_HA)
                       (G.connectedTo (p :: M0.Process) M0.IsParentOf g)

    -- We allow stopping m0d when there are no running Mero processes.
    guard (M0.BootLevel (-1)) = do
      stillUnstopped <- getGraph <&> \g -> filter
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
      stillUnstopped <- unstoppedProcesses (== CI.PLM0d 1)
      return $ null stillUnstopped
    guard (M0.BootLevel 1) = do
      -- We allow stopping a process on level 1 if there are no running
      -- PLM0t1fs processes or controlled PLClovis processes
      stillUnstopped <- unstoppedProcesses
                          (\case (CI.PLClovis _ CI.Managed) -> True
                                 CI.PLM0t1fs                -> True
                                 _                          -> False)
      return $ null stillUnstopped
    guard (M0.BootLevel 2) = return True
    guard (M0.BootLevel 3) = return True
    guard (M0.BootLevel _) = return False

    unstoppedProcesses procTypePred = getGraph <&> \rg ->
      (Process.getTypedP procTypePred rg) & filter
      (\proc -> not . null $
        [() | M0.getState proc rg `elem` [ M0.PSOnline
                                         , M0.PSQuiescing
                                         , M0.PSStarting
                                         , M0.PSStopping
                                         ]
           , Just (node :: M0.Node) <- [G.connectedFrom M0.IsParentOf proc rg]
           , M0.getState node rg `notElem` [M0.NSFailed, M0.NSFailedUnrecoverable]
        ]
      )

-- | Get an aggregate cluster status report.
getClusterStatus :: G.Graph -> Maybe M0.MeroClusterState
getClusterStatus rg = let
    dispo = G.connectedTo Cluster Has rg
    runLevel = G.connectedTo Cluster M0.RunLevel rg
    stopLevel = G.connectedTo Cluster M0.StopLevel rg
  in M0.MeroClusterState <$> dispo <*> runLevel <*> stopLevel

-- | Is the cluster completely stopped?
--
-- Cluster is completely stopped when all processes on non-failed nodes
-- are offline, failed or unknown.
isClusterStopped :: G.Graph -> Bool
isClusterStopped rg = null $
  [ proc
  | node <- M0.getM0Nodes rg
  , nodeIsOK (M0.getState node rg)
  , proc :: M0.Process <- G.connectedTo node M0.IsParentOf rg
  , procIsUp (M0.getState proc rg)
  , all (\svc -> M0.s_type svc /= CST_HA) $ G.connectedTo proc M0.IsParentOf rg
  ]
  where
    nodeIsOK M0.NSFailed              = False
    nodeIsOK M0.NSFailedUnrecoverable = False
    nodeIsOK _                        = True

    procIsUp M0.PSOffline    = False
    procIsUp (M0.PSFailed _) = False
    procIsUp M0.PSUnknown    = False
    procIsUp _               = True

-- | Send a request to configure the given mero process. Constructs
-- the appropriate 'ProcessConfig' (which depends on whether the
-- process in @confd@ or not) and sends it to @halon:m0d@.
configureMeroProcess :: (MeroToSvc -> Process ())
                     -> M0.Process
                     -> ProcessRunType
                     -> PhaseM RC a UUID.UUID
configureMeroProcess sender p runType = do
  rg <- getGraph
  uid <- liftIO nextRandom
  conf <- if any (\s -> M0.s_type s == CST_CONFD)
               $ G.connectedTo p M0.IsParentOf rg
          then ProcessConfigLocal p <$> syncToBS
          else return $! ProcessConfigRemote p
  let env = G.connectedTo p Has rg
  liftProcess . sender . ProcessMsg $!
    ConfigureProcess runType conf env (runType == M0D) uid
  return uid

-- | Dispatch a request to start @halon:m0d@ on the given
-- 'Cas.Host'.
startMeroService :: Cas.Host -> R.Node -> PhaseM RC a ()
startMeroService host node = do
  Log.rcLog' Log.DEBUG $ "Trying to start mero service on " ++ show (host, node)
  rg <- getGraph
  mprof <- theProfile
  kaFreq <- getHalonVar _hv_keepalive_frequency
  kaTimeout <- getHalonVar _hv_keepalive_timeout
  naDelay <- getHalonVar _hv_notification_aggr_delay
  naMaxDelay <- getHalonVar _hv_notification_aggr_max_delay
  mHaAddr <- lookupHostHAAddress host >>= \case
    Just addr -> return $ Just addr
    -- if there is no HA service running to give us an endpoint, pass
    -- the lnid to mkHAAddress instead of the host address: trust user
    -- setting
    Nothing -> return $ fmap (\(M0.LNid lnid) -> haAddress lnid)
                             (listToMaybe -- XXX Don't ignore other addresses?
                              $ G.connectedTo host Has rg)
  minfo <- return $! do
    prof <- mprof
    haAddr <- mHaAddr
    uuid <- G.connectedTo host Has rg
    let mconf = listToMaybe
                  [ (proc, srvHA, srvRM)
                  | m0node :: M0.Node <- G.connectedTo host Runs rg
                  , proc :: M0.Process <- G.connectedTo m0node M0.IsParentOf rg
                  , srvHA :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
                  , M0.s_type srvHA == CST_HA
                  , srvRM :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
                  , M0.s_type srvRM == CST_RMS
                  ]
    mconf <&> \(proc, srvHA, srvRM) ->
      let conf = MeroConf (T.unpack $ encodeEndpoint haAddr)
                          (M0.fid prof)
                          (M0.fid proc)
                          (M0.fid srvHA)
                          (M0.fid srvRM)
                          kaFreq
                          kaTimeout
                          naDelay
                          naMaxDelay
                          (MeroKernelConf uuid)
      in (encodeP $ ServiceStartRequest Start node (lookupM0d rg) conf [], proc)
  for_ minfo $ \(msg, proc) -> do
    _ <- applyStateChanges [stateSet proc Tr.processStarting]
    promulgateRC msg

-- | It may happen that a node reboots (either through halon or
-- through external means) during cluster's lifetime. The below
-- function re-triggers the mero part of the bootstrap on the node.
--
-- Any halon services that need restarting will have been triggered in
-- @node-up@ rule. @halon:m0d@ is excluded from that as that
-- particular service is going to be restarted as part of the node
-- bootstrap.
retriggerMeroNodeBootstrap :: M0.Node -> PhaseM RC a ()
retriggerMeroNodeBootstrap n = do
  rg <- getGraph
  case G.connectedTo Cluster Has rg of
    Just M0.ONLINE -> restartMeroOnNode
    cst -> Log.rcLog' Log.DEBUG $
             "Not trying to retrigger mero as cluster state is " ++ show cst
  where
    restartMeroOnNode = do
      rg <- getGraph
      case G.connectedFrom Runs n rg of
        Nothing -> Log.rcLog' Log.DEBUG $ "Not a mero node: " ++ show n
        Just h  -> announceTheseMeroHosts [h] (\_ _ -> True)

-- | Send notifications about new mero nodes and new mero servers for
-- the given set of 'Cas.Host's.
--
-- Used during startup by 'requestClusterStart'.
announceTheseMeroHosts :: [Cas.Host] -- ^ Candidate hosts
                       -> (M0.Node -> G.Graph -> Bool) -- ^ Predicate on nodes belonging to hosts
                       -> PhaseM RC a ()
announceTheseMeroHosts hosts p = do
  rg' <- getGraph
  let clientHosts =
        [ host | host <- hosts
               , G.isConnected host Has Cas.HA_M0CLIENT rg' -- which are clients
               ]
      serverHosts =
        [ host | host <- hosts
               , G.isConnected host Has Cas.HA_M0SERVER rg'
               ]

      -- Don't announced failed nodes
      hostsToNodes hs = [ n | h <- hs, n <- G.connectedTo h Runs rg'
                            , p n rg' ]

      serverNodes = hostsToNodes serverHosts :: [M0.Node]
      clientNodes = hostsToNodes clientHosts :: [M0.Node]
  Log.rcLog' Log.DEBUG $ "Sending messages about these new mero nodes: "
      ++ show ((clientNodes, clientHosts), (serverNodes, serverHosts))
  for_ (serverNodes++clientNodes) $ promulgateRC . StartProcessesOnNodeRequest


-- | Get an 'Interface' we can send on to the halon:m0d service on the
-- given node. This interface is only provided if the process on the
-- node is 'M0.PSOnline'.
--
-- You should in general not use 'getInterface' for this service
-- yourself without performing this check if you plan on
-- communication.
getRunningMeroInterface :: M0.Node -> G.Graph -> Maybe (Interface MeroToSvc MeroFromSvc)
getRunningMeroInterface m0node rg =
  let m0ds =
        [ () | p :: M0.Process <- G.connectedTo m0node M0.IsParentOf rg
             , M0.getState p rg == M0.PSOnline
             , s :: M0.Service <- G.connectedTo p M0.IsParentOf rg
             , M0.s_type s == CST_HA
             , M0.getState s rg == M0.SSOnline ]
  in case m0ds of
       [] -> Nothing
       _ -> Just . getInterface $! lookupM0d rg
