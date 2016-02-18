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
  , updateDriveState
  , createMeroKernelConfig
  , createMeroClientConfig
  , startMeroService
  , startNodeProcesses
  )
where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf as Conf
import HA.RecoveryCoordinator.Actions.Mero.Core
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Actions.Mero.Failure

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

import Control.Category
import Control.Distributed.Process
import Control.Monad (forM, join)

import Data.Foldable (forM_, traverse_)
import Data.Proxy
import Data.Maybe (listToMaybe)
import Data.UUID.V4 (nextRandom)

import Network.CEP

import System.Posix.SysInfo

import Prelude hiding ((.), id)

updateDriveState :: M0.SDev -- ^ Drive to update state
                 -> M0.ConfObjectState -- ^ State to update to
                 -> PhaseM LoopState l ()

-- | For transient failures, we may need to create a new pool version.
updateDriveState m0sdev M0.M0_NC_TRANSIENT = do
  -- Update state in RG
  modifyGraph $ G.connectUnique m0sdev Is M0.M0_NC_TRANSIENT
  graph <- getLocalGraph
  let m0disks = G.connectedTo m0sdev M0.IsOnHardware graph :: [M0.Disk]
  traverse_ (\m0disk -> modifyGraph $ G.connectUnique m0disk Is M0.M0_NC_TRANSIENT)
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
  liftProcess $ say $ "updating to " ++ show x
  -- Update state in RG
  modifyGraph $ G.connect m0sdev Is x
  graph <- getLocalGraph
  let m0disks = G.connectedTo m0sdev M0.IsOnHardware graph :: [M0.Disk]
  traverse_ (\m0disk -> modifyGraph $ G.connect m0disk Is x) m0disks
  -- Quite possibly we need to wait for synchronization result here, because
  -- otherwise we may notifyMero multiple times (if consesus will be lost).
  -- however in opposite case we may never notify mero if RC will die after
  -- sync, but before it notified mero.
  syncGraph (return ())
  -- Notify Mero
  liftProcess $ say $ show (m0sdev, m0disks, x)
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
          >>> G.connect fs M0.IsParentOf m0node
          >>> G.connect host Has Castor.HA_M0CLIENT
          >>> G.connect host Runs m0node
            $ rg
    return rg'

-- | Start all Mero processes labelled with the specified process label on
--   a given node.
startNodeProcesses :: Castor.Host
                   -> (TypedChannel ProcessControlMsg)
                   -> M0.ProcessLabel
                   -> Bool -- ^ Run mkfs? Ignored for m0t1fs processes.
                   -> PhaseM LoopState a ()
startNodeProcesses host (TypedChannel chan) label mkfs = do
    phaseLog "action" $ "Trying to start all processes with label "
                      ++ show label
                      ++ " on host "
                      ++ show host
    rg <- getLocalGraph
    let procs =  [ p
                 | m0node <- G.connectedTo host Runs rg :: [M0.Node]
                 , p <- G.connectedTo m0node M0.IsParentOf rg
                 , G.isConnected p Has label rg
                 ]
    phaseLog "processes" $ show (fmap M0.fid (procs :: [M0.Process]))
    msg <- StartProcesses <$> case (label, mkfs) of
            (M0.PLM0t1fs, _) -> forM procs $ (\proc -> (M0T1FS,) <$> runConfig proc rg)
            (_, True) -> join <$> forM procs
                          (\proc -> (\x -> [(M0MKFS,x), (M0D, x)])
                            <$> runConfig proc rg)
            (_, False) -> forM procs $ (\proc -> (M0D,) <$> runConfig proc rg)
    liftProcess $ sendChan chan msg
  where
    runConfig proc rg = case runsMgs proc rg of
      True -> syncToBS >>= \bs -> return $
                ProcessConfigLocal (M0.fid proc) (M0.r_endpoint proc) bs
      False -> return $ ProcessConfigRemote (M0.fid proc) (M0.r_endpoint proc)
    runsMgs proc rg =
      not . null $ [ () | M0.Service{ M0.s_type = CST_MGS }
                          <- G.connectedTo proc M0.IsParentOf rg
                   ]

startMeroService :: Castor.Host -> Res.Node -> PhaseM LoopState a ()
startMeroService host node = do
  phaseLog "action" $ "Trying to start mero service on "
                    ++ show (host, node)
  rg <- getLocalGraph
  mprofile <- Conf.getProfile
  mHaAddr <- Conf.lookupHostHAAddress host
  mapM_ promulgateRC $ do
    profile <- mprofile
    M0.LNid lnid <- listToMaybe . G.connectedTo host Has $ rg
    uuid <- listToMaybe $ G.connectedTo host Has rg
    let haAddr = maybe (lnid ++ haAddress) id mHaAddr
        conf = MeroConf haAddr (fidToStr $ M0.fid profile)
                (MeroKernelConf uuid)
    return $ encodeP $ ServiceStartRequest Start node m0d conf []
