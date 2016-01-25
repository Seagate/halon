{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE TupleSections         #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.RecoveryCoordinator.Actions.Mero
  ( module Conf
  , module HA.RecoveryCoordinator.Actions.Mero.Core
  , module HA.RecoveryCoordinator.Actions.Mero.Spiel
  , updateDriveState
  , storeMeroNodeInfo
  , startMeroClientService
  , startMeroServerService
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
import Control.Monad.IO.Class
import Data.ByteString (ByteString)
import Data.Foldable (forM_)
import Data.Proxy
import Data.Maybe (listToMaybe, isJust)
import Data.UUID.V4 (nextRandom)
import System.Posix.SysInfo
import Network.CEP
import Prelude hiding ((.))

updateDriveState :: M0.SDev -- ^ Drive to update state
                 -> M0.ConfObjectState -- ^ State to update to
                 -> PhaseM LoopState l ()

-- | For transient failures, we may need to create a new pool version.
updateDriveState m0sdev M0.M0_NC_TRANSIENT = do
  -- Update state in RG
  modifyGraph $ G.connectUnique m0sdev Is M0.M0_NC_TRANSIENT
  syncGraph (return ()) -- possibly we need to wait here, but I see no good
                        -- reason for that.
  -- If using dynamic failure sets, generate failure set
  graph <- getLocalGraph
  mstrategy <- getCurrentStrategy
  forM_ mstrategy $ \strategy ->
    forM_ (onFailure strategy graph) $ \graph' -> do
      putLocalGraph graph'
      syncAction Nothing M0.SyncToConfdServersInRG
  -- Notify Mero
  notifyMero [M0.AnyConfObj m0sdev] M0.M0_NC_TRANSIENT

-- | For all other states, we simply update in the RG and notify Mero.
updateDriveState m0sdev x = do
  -- Update state in RG
  modifyGraph $ G.connect m0sdev Is x
  -- Quite possibly we need to wait for synchronization result here, because
  -- otherwise we may notifyMero multiple times (if consesus will be lost).
  -- however in opposite case we may never notify mero if RC will die after
  -- sync, but before it notified mero.
  syncGraph (return ())
  -- Notify Mero
  notifyMero [M0.AnyConfObj m0sdev] x

-- | RMS service address.
rmsAddress :: String
rmsAddress = ":12345:41:301"

-- | Halon service addres.
haAddress :: String
haAddress = ":12345:35:101"

-- | Store information about mero host in Resource Graph.
--
-- If the 'Host' already contains all the required information, no new
-- information will be added.
storeMeroNodeInfo :: M0.Filesystem -> Castor.Host -> HostHardwareInfo
                  -> Castor.HostAttr -- ^ Attribute to attach, client/server
                  -> PhaseM LoopState a ()
storeMeroNodeInfo fs host (HostHardwareInfo memsize cpucnt nid) hattr =
  modifyLocalGraph $ \rg -> do
    uuid <- liftIO nextRandom
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
          >>> G.connect fs M0.IsParentOf m0node
          >>> G.connect host Has hattr
          >>> G.connect host Has (M0.LNid nid)
          >>> G.connect host Runs m0node
          >>> G.connectUnique host Has uuid
            $ rg
    return rg'

-- | Convert 'Fid' to 'String'. Strips the angled brackets around the
-- fid that the 'Show' instance produces.
fidToStr :: Fid -> String
fidToStr = init . tail . show

startMeroServerService :: Castor.Host -> Res.Node
                       -> Maybe ByteString
                       -> PhaseM LoopState a ()
startMeroServerService host node confString = do
  phaseLog "startMeroServerService"
         $ "Trying to start mero service on " ++ show (host, node)
  mprofile <- Conf.getProfile
  rg <- getLocalGraph
  let mmsg = do
       M0.LNid lnid <- listToMaybe . G.connectedTo host Has $ rg
       uuid <- listToMaybe $ G.connectedTo host Has rg
       profileFid <- fidToStr . M0.fid <$> mprofile
       (processId,endpoint) <-
          listToMaybe [ (fidToStr $ M0.fid process, M0.r_endpoint process)
                      | m0node <- G.connectedTo host Runs rg :: [M0.Node]
                      , process <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
                      ]
       let servconf = fmap (,processId) confString
       let conf = MeroConf (lnid ++ haAddress) profileFid
                    (MeroKernelConf uuid)
                    (MeroServerConf servconf endpoint)
       return $ encodeP $ ServiceStartRequest Start node m0d conf []
  phaseLog "startMeroServerService" $ "Got msg: " ++ show (isJust mmsg)
  forM_ mmsg promulgateRC

startMeroClientService :: Castor.Host -> Res.Node -> PhaseM LoopState a ()
startMeroClientService host node = do
    mprofile <- Conf.getProfile
    rg <- getLocalGraph
    let mmsg = do
         (M0.LNid lnid) <- listToMaybe . G.connectedTo host Has $ rg
         uuid <- listToMaybe . G.connectedTo host Has $ rg
         profileFid <- fidToStr . M0.fid <$> mprofile
         (processId,endpoint) <-
            listToMaybe [ (fidToStr $ M0.fid process, M0.r_endpoint process)
                        | m0node <- G.connectedTo host Runs rg :: [M0.Node]
                        , process <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
                        ]
         let conf = MeroConf (lnid++haAddress) profileFid
                      (MeroKernelConf uuid)
                      (MeroClientConf processId endpoint)
         return $ encodeP $ ServiceStartRequest Start node m0d conf []
    forM_ mmsg promulgateRC
