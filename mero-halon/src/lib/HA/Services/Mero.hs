-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE LambdaCase            #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Mero
    ( MeroChannel(..)
    , TypedChannel(..)
    , DeclareMeroChannel(..)
    , NotificationMessage(..)
    , ProcessRunType(..)
    , ProcessConfig(..)
    , ProcessControlMsg(..)
    , ProcessControlResultMsg(..)
    , MeroConf(..)
    , MeroKernelConf(..)
    , m0d
    , HA.Services.Mero.__remoteTableDecl
    , HA.Services.Mero.Types.__remoteTable
    , m0dProcess__sdict
    , m0dProcess__tdict
    , m0d__static
    , meroRules
    , notifyMero
    ) where

import HA.EventQueue.Producer (expiate, promulgate, promulgateWait)
import HA.RecoveryCoordinator.Actions.Core
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState)
import HA.Service
import HA.Services.Mero.CEP (meroRulesF)
import HA.Services.Mero.Types
import qualified HA.ResourceGraph as G

import qualified Mero.Notification
import Mero.Notification.HAState (Note(..))
import Mero.ConfC (Fid, ServiceType(..), fidToStr)

import Network.CEP
import qualified Network.RPC.RPCLite as RPC

import Control.Distributed.Process.Closure
  ( remotableDecl
  , mkStatic
  , mkStaticClosure
  )
import Control.Distributed.Static
  ( staticApply )
import Control.Distributed.Process
import Control.Monad (forever, void)
import Data.Foldable (forM_, asum)
import qualified Control.Monad.Catch as Catch

import Control.Monad.Trans.Maybe
import qualified Data.ByteString as BS
import Data.Char (toUpper)
import Data.List (partition)
import Data.Maybe (listToMaybe, maybeToList)
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import System.FilePath
import System.Directory
import qualified System.SystemD.API as SystemD

-- | Store information about communication channel in resource graph.
sendMeroChannel :: SendPort NotificationMessage
                -> SendPort ProcessControlMsg
                -> Process ()
sendMeroChannel cn cc = do
  pid <- getSelfPid
  let chan = DeclareMeroChannel
              (ServiceProcess pid) (TypedChannel cn) (TypedChannel cc)
  void $ promulgate chan

statusProcess :: RPC.ServerEndpoint
              -> ProcessId
              -> ReceivePort NotificationMessage
              -> Process ()
statusProcess ep pid rp = link pid >> (forever $ do
    NotificationMessage set addrs <- receiveChan rp
    forM_ addrs $ \addr ->
      Mero.Notification.notifyMero ep (RPC.rpcAddress addr) set
  )

-- | Process responsible for controlling the system level
--   Mero processes running on this node.
controlProcess :: MeroConf
               -> ProcessId -- ^ Parent process to link to
               -> ReceivePort ProcessControlMsg
               -> Process ()
controlProcess mc pid rp = link pid >> (forever $ receiveChan rp >>= \case
    StartProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ mapM (uncurry $ startProcess mc) procs
      promulgateWait $ ProcessControlResultMsg nid results
  )

--------------------------------------------------------------------------------
-- Mero Process control
--------------------------------------------------------------------------------

confXCPath :: FilePath
confXCPath = "/var/mero/confd/conf.xc"

startProcess :: MeroConf
             -> ProcessRunType
             -> ProcessConfig
             -> IO (Either Fid (Fid, String))
startProcess mc run conf = flip Catch.catch handler $ do
    putStrLn $ "m0d: startProcess: " ++ show procFid
            ++ " with type " ++ show run
            ++ " and config " ++ show conf
    confXC <- maybeWriteConfXC conf
    unit <- writeSysconfig mc run procFid m0addr confXC
    _ <- SystemD.startService $ unit ++ fidToStr procFid
    return $ Left procFid
  where
    maybeWriteConfXC (ProcessConfigLocal _ _ bs) = do
      liftIO $ writeConfXC bs
      return $ Just confXCPath
    maybeWriteConfXC _ = return Nothing
    (procFid, m0addr) = case conf of
      ProcessConfigLocal x y _ -> (x,y)
      ProcessConfigRemote x y -> (x,y)
    handler :: Catch.SomeException -> IO (Either Fid (Fid, String))
    handler e = return $
      Right (procFid, show e)

-- | Write out the conf.xc file for a confd server.
writeConfXC :: BS.ByteString -- ^ Contents of conf.xc file
            -> IO ()
writeConfXC conf = do
  createDirectoryIfMissing True $ takeDirectory confXCPath
  BS.writeFile confXCPath conf

-- | Write out Systemd sysconfig file appropriate to process. Returns the
--   unit name of the corresponding unit to start.
writeSysconfig :: MeroConf
               -> ProcessRunType
               -> Fid -- ^ Process fid
               -> String -- ^ Endpoint address
               -> Maybe String -- ^ Confd address?
               -> IO String
writeSysconfig MeroConf{..} run procFid m0addr confdPath = do
    putStrLn $ "m0d: Writing sysctlFile: " ++ fileName
    _ <- SystemD.sysctlFile fileName $
      [ ("MERO_" ++ fmap toUpper prefix ++ "_EP", m0addr)
      , ("MERO_HA_EP", mcHAAddress)
      , ("MERO_PROFILE_FID", mcProfile)
      ] ++ maybeToList (("MERO_CONF_XC",) <$> confdPath)
    return $ unit
  where
    fileName = prefix ++ "-" ++ fidToStr procFid
    (prefix, unit) = case run of
      M0T1FS -> ("m0t1fs", "m0t1fs@")
      M0D -> ("m0d", "m0d@")
      M0MKFS -> ("m0d", "mero-mkfs@")

remotableDecl [ [d|

  m0d :: Service MeroConf
  m0d = Service
          meroServiceName
          $(mkStaticClosure 'm0dProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictMeroConf))

  m0dProcess :: MeroConf -> Process ()
  m0dProcess conf = bracket_ startKernel stopKernel $ do
      bracket_ bootstrap teardown $ do
        self <- getSelfPid
        c <- withEp $ \ep -> spawnChannelLocal (statusProcess ep self)
        cc <- spawnChannelLocal (controlProcess conf self)
        sendMeroChannel c cc
        say $ "Starting service m0d on mero client"
        go
    where
      haAddr = RPC.rpcAddress $ mcHAAddress conf
      withEp = Mero.Notification.withServerEndpoint haAddr
      -- Kernel
      startKernel = liftIO $ do
        SystemD.sysctlFile "mero-kernel"
          [ ("MERO_NODE_UUID", UUID.toString $ mkcNodeUUID (mcKernelConfig conf))
          ]
        SystemD.startService "mero-kernel"
      stopKernel = liftIO $ SystemD.stopService "mero-kernel"
      bootstrap = do
        Mero.Notification.initialize haAddr
      teardown = do
        Mero.Notification.finalize

      -- mainloop
      go = do
          let shutdownAndTellThem = do
                node <- getSelfNode
                pid  <- getSelfPid
                expiate . encodeP $ ServiceFailed (Node node) m0d pid
          receiveWait $
            [ match $ \buf ->
                case examine buf of
                   True -> go
                   False -> shutdownAndTellThem
            , match $ \() ->
                shutdownAndTellThem
            ]

      -- In lieu of properly parsing the YAML output,
      -- we just aply a simple heuristic. This may or
      -- may not be adequate in the long term. Returns
      -- true if okay, false otherwise.
      examine :: [String] -> Bool
      examine xs = not $ or $ map hasError xs
         where
           hasError line =
              let w = words line
               in if length w > 0
                     then head w == "error:" ||
                          last w == "FAILED"
                     else False

    |] ]

meroRules :: Definitions LoopState ()
meroRules = meroRulesF m0d

-- | Combine @ConfObj@s and a @ConfObjectState@ into a 'Set' and
-- send it to every mero service running on the cluster.
notifyMero :: [M0.AnyConfObj] -- ^ List of resources (instance of @ConfObj@)
           -> ConfObjectState
           -> PhaseM LoopState l ()
notifyMero cs st = do
  phaseLog "action" "Sending configuration update to mero services"
  rg <- getLocalGraph
  let hosts = G.getResourcesOfType rg :: [Host]
  forM_ hosts $ \host -> do
     mchan <- runMaybeT $ asum (MaybeT . lookupMeroChannelByNode <$> G.connectedTo host Runs rg)
     let recipients = Set.fromList (fst <$> nha) Set.\\ Set.fromList (fst <$> ha)
         (nha, ha) = partition ((/=) CST_HA . snd)
                   [ (endpoint, stype)
                   | m0cont <- G.connectedFrom M0.At host rg :: [M0.Controller]
                   , m0node <- G.connectedFrom M0.IsOnHardware m0cont rg :: [M0.Node]
                   , m0proc <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
                   , service <- G.connectedTo m0proc M0.IsParentOf rg :: [M0.Service]
                   , let stype = M0.s_type service
                   , endpoint <- M0.s_endpoints service
                   ]
     case mchan of
       Nothing -> do
         node <- liftProcess getSelfNode
         lookupMeroChannelByNode (Node node) >>= \case
            Just (TypedChannel chan) -> do
               phaseLog "warning" $ "HA.Service.Mero.notifyMero: can't find remote service for"
                                  ++ show host
                                  ++ ", sending from local"
               phaseLog "debug" $ show setEvent
               liftProcess $ sendChan chan $ NotificationMessage setEvent (Set.toList recipients)
            Nothing -> phaseLog "error" $ "HA.Service.Mero.notifyMero: cannot neither MeroChannel on "
                                      ++ show host
                                      ++ " nor local channel."
       Just (TypedChannel chan) -> liftProcess $
         sendChan chan $ NotificationMessage setEvent (Set.toList recipients)
  where
    getFid (M0.AnyConfObj a) = M0.fid a
    setEvent :: Mero.Notification.Set
    setEvent = Mero.Notification.Set $ map (flip Note st . getFid) cs

lookupMeroChannelByNode :: Node -> PhaseM LoopState l (Maybe (TypedChannel NotificationMessage))
lookupMeroChannelByNode node = do
   rg <- getLocalGraph
   let mlchan = listToMaybe
         [ chan | sp   <- G.connectedTo node Runs rg :: [ServiceProcess MeroConf]
                , chan <- G.connectedTo sp MeroChannel rg ]
   return mlchan 
