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
    , ProcessControlResultStopMsg(..)
    , MeroConf(..)
    , MeroKernelConf(..)
    , m0d
    , HA.Services.Mero.__remoteTableDecl
    , HA.Services.Mero.Types.__remoteTable
    , m0dProcess__sdict
    , m0dProcess__tdict
    , m0d__static
    , meroRules
    , createSet
    , notifyMero
    , notifyMeroBlocking
    , notifyMeroAndThen
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
import Mero.Notification (Set)
import Mero.Notification.HAState (Note(..), HAStateException)
import Mero.ConfC (Fid, ServiceType(..), fidToStr)

import Network.CEP
import qualified Network.RPC.RPCLite as RPC

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, IOException)
import qualified Control.Distributed.Process.Timeout as PT (timeout)
import Control.Distributed.Process.Closure
  ( remotableDecl
  , mkStatic
  , mkStaticClosure
  )
import Control.Distributed.Static
  ( staticApply )
import Control.Distributed.Process hiding (catch, onException, bracket_)
import Control.Monad.Catch (catch, onException, bracket_)
import Control.Monad (forever, join, void, when)
import qualified Control.Monad.Catch as Catch
import Control.Monad.Trans.Maybe

import qualified Data.ByteString as BS
import Data.Char (toUpper)
import Data.Foldable (forM_, asum, traverse_)
import Data.Traversable (forM)
import Data.List (partition)
import Data.Maybe (catMaybes, listToMaybe, maybeToList)
import qualified Data.Set as Set
import qualified Data.UUID as UUID

import System.Exit
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

-- | Tell the RC that something has failed
notifyBootstrapFailure :: String -> Process ()
notifyBootstrapFailure = void . promulgate . M0.BootstrapFailedNotification

statusProcess :: RPC.ServerEndpoint
              -> ProcessId
              -> ReceivePort NotificationMessage
              -> Process ()
statusProcess ep pid rp = do
    -- TODO: When mero can handle exceptions caught here, report them to the RC.
    link pid
    forever $ do
      NotificationMessage set addrs subs <- receiveChan rp
      forM_ addrs $ \addr ->
        let logError e =
              say $ "statusProcess: notifyMero failed: " ++ show (pid, addr, e)
        in do
          ( Mero.Notification.notifyMero ep (RPC.rpcAddress addr) set
            `catch` \(e :: IOException) -> logError e
            ) `catch` \(e :: HAStateException) -> logError e
          traverse_ (flip usend $ NotificationAck ()) subs
   `catch` \(e :: SomeException) -> do
      say $ "statusProcess terminated: " ++ show (pid, e)
      Catch.throwM e

-- | Process responsible for controlling the system level
--   Mero processes running on this node.
controlProcess :: MeroConf
               -> ProcessId -- ^ Parent process to link to
               -> ReceivePort ProcessControlMsg
               -> Process ()
controlProcess mc pid rp = link pid >> (forever $ receiveChan rp >>= \case
    StartProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ join <$> mapM (uncurry $ startProcesses mc) procs
      promulgateWait $ ProcessControlResultMsg nid results
    StopProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ fmap concat $ forM procs $ \(roles, conf) ->
        forM (reverse roles) $ \role -> stopProcess role conf
      promulgateWait $ ProcessControlResultStopMsg nid results
  )


--------------------------------------------------------------------------------
-- Mero Process control
--------------------------------------------------------------------------------

confXCPath :: FilePath
confXCPath = "/var/mero/confd/conf.xc"

-- | Start multiple processes in a chain. If earlier processes fail,
--   subsequent ones will not be run.
startProcesses :: MeroConf
               -> [ProcessRunType]
               -> ProcessConfig
               -> IO [Either Fid (Fid, String)]
startProcesses _ [] _ = error "No processes to start."
startProcesses mc [x] pc = (:[]) <$> startProcess mc x pc
startProcesses mc (x:xc) pc = do
  res <- startProcess mc x pc
  case res of
    Left _ -> startProcesses mc xc pc >>= return . (res:)
    Right _ -> return $ [res]

startProcess :: MeroConf
             -> ProcessRunType
             -> ProcessConfig
             -> IO (Either Fid (Fid, String))
startProcess mc run conf = flip Catch.catch handler $ do
    putStrLn $ "m0d: startProcess: " ++ show procFid
            ++ " with type(s) " ++ show run
    confXC <- maybeWriteConfXC conf
    unit <- writeSysconfig mc run procFid m0addr confXC
    ec <- SystemD.startService $ unit ++ fidToStr procFid
    -- XXX: This hack is required to create global barrier between mkfs
    -- and m0d withing the cluster. mkfs usually takes less than 10s
    -- thus we choose 20s delay to guarantee protection.
    -- For more details see HALON-146.
    when (run == M0MKFS) $ threadDelay (20*1000000)
    return $ case ec of
      ExitSuccess -> Left procFid
      ExitFailure x ->
        Right (procFid, "Unit failed to start with exit code " ++ show x)
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

-- | Stop running mero service.
stopProcess :: ProcessRunType -> ProcessConfig -> IO (Either Fid (Fid,String))
stopProcess run conf = flip Catch.catch handler $ do
    let munit = case run of
          M0T1FS -> Just $ "m0t1fs@" ++ fidToStr procFid
          M0D    -> Just $ "m0d@" ++ fidToStr procFid
          M0MKFS  -> Nothing
    case munit of
      Just unit -> do putStrLn $ "m0d: stopProcess: " ++ unit ++ " with type(s) " ++ show run
                      ec <- SystemD.stopService $ unit ++ ".service"
                      case ec of
                        ExitSuccess -> return $ Left procFid
                        ExitFailure x -> do
                          putStrLn $ "m0d: stopProcess failed."
                          return $ Right (procFid, "Unit failed to stop with exit code " ++ show x)
      Nothing -> return (Left procFid)
    where
      procFid = case conf of
        ProcessConfigLocal x _ _ -> x
        ProcessConfigRemote x _  -> x
      handler :: Catch.SomeException -> IO (Either Fid (Fid, String))
      handler e = return $ Right (procFid, show e)


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
  m0dProcess conf = do
    say "[Service:m0d] starting."
    Catch.bracket startKernel (\_ -> stopKernel) $ \rc -> do
      say "[Service:m0d] Kernel module loaded."
      case rc of
        ExitSuccess -> bracket_ bootstrap teardown $ do
          self <- getSelfPid
          c <- withEp $ \ep -> spawnChannelLocal (statusProcess ep self)
          cc <- spawnChannelLocal (controlProcess conf self)
          sendMeroChannel c cc
          say "[Service:m0d] Starting service m0d on mero client"
          go
        ExitFailure i ->
          notifyBootstrapFailure $ "mero-kernel service failed to start: " ++ show i
    where
      haAddr = RPC.rpcAddress $ mcHAAddress conf
      withEp = Mero.Notification.withServerEndpoint haAddr
      -- Kernel
      startKernel = liftIO $ do
        SystemD.sysctlFile "mero-kernel"
          [ ("MERO_NODE_UUID", UUID.toString $ mkcNodeUUID (mcKernelConfig conf))
          ]
        SystemD.startService "mero-kernel"
      -- XXX: halon uses mero kernel module so it's not possible to
      -- unload that.
      stopKernel = return () -- liftIO $ SystemD.stopService "mero-kernel"
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

-- | Return the set of notification channels available in the cluster.
--   This function logs, but does not error, if it cannot find channels
--   for every host in the cluster.
getNotificationChannels :: PhaseM LoopState l [(SendPort NotificationMessage, [String])]
getNotificationChannels = do
  rg <- getLocalGraph
  let hosts = G.getResourcesOfType rg :: [Host]
  things <- forM hosts $ \host -> do
     mchan <- runMaybeT $ asum (MaybeT . lookupMeroChannelByNode <$> G.connectedTo host Runs rg)
     let recipients = Set.fromList (fst <$> nha) Set.\\ Set.fromList (fst <$> ha)
         (nha, ha) = partition ((/=) CST_HA . snd)
                   [ (endpoint, stype)
                   | m0cont <- G.connectedFrom M0.At host rg :: [M0.Controller]
                   , m0node <- G.connectedFrom M0.IsOnHardware m0cont rg :: [M0.Node]
                   , m0proc <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
                   , G.isConnected m0proc Is M0.PSOnline rg
                   , service <- G.connectedTo m0proc M0.IsParentOf rg :: [M0.Service]
                   , let stype = M0.s_type service
                   , endpoint <- M0.s_endpoints service
                   ]
     (fmap (,Set.toList recipients)) <$> case mchan of
       Nothing -> do
         node <- liftProcess getSelfNode
         lookupMeroChannelByNode (Node node) >>= \case
            Just (TypedChannel chan) -> do
               phaseLog "warning" $ "HA.Service.Mero.notifyMero: can't find remote service for"
                                  ++ show host
                                  ++ ", sending from local"
               return $ Just chan
            Nothing -> do
              phaseLog "error" $ "HA.Service.Mero.notifyMero: cannot neither MeroChannel on "
                              ++ show host
                              ++ " nor local channel."
              return Nothing
       Just (TypedChannel chan) -> return $ Just chan
  return $ catMaybes things

-- | Create a set event from a set of conf objects and a state.
--   TODO: This is only temporary until we move to `stateSet`
createSet :: [M0.AnyConfObj] -> ConfObjectState -> Set
createSet cs st = setEvent
  where
    getFid (M0.AnyConfObj a) = M0.fid a
    setEvent :: Mero.Notification.Set
    setEvent = Mero.Notification.Set $ map (flip Note st . getFid) cs

notifyMeroBlocking :: Set
                   -> PhaseM LoopState l Bool
notifyMeroBlocking setEvent = do
  res <- liftIO $ newEmptyMVar
  notifyMeroAndThen setEvent
    (liftIO $ putMVar res True)
    (liftIO $ putMVar res False)
  liftIO $ takeMVar res

notifyMeroAndThen :: Set
                  -> Process () -- ^ Action on success
                  -> Process () -- ^ Action on failure
                  -> PhaseM LoopState l ()
notifyMeroAndThen setEvent fsucc ffail = do
    phaseLog "action" "Sending configuration update to mero services"
    chans <- getNotificationChannels
    liftProcess $ do
      self <- getSelfPid
      void $ spawnLocal $ do
        link self
        sendChansBlocking chans
  where
    -- Send a message to all channels and block until each has replied
    sendChansBlocking :: [(SendPort NotificationMessage, [String])] -> Process ()
    sendChansBlocking chans =
      ((callLocal $ PT.timeout 1000000 $ do
          selfLocal <- getSelfPid
          forM_ chans $ \(chan, recipients) ->
            sendChan chan $ NotificationMessage setEvent recipients [selfLocal]
          forM_ chans $ const (expect :: Process NotificationAck)
       ) `onException` ffail)
      >>= maybe ffail (const fsucc)

notifyMero :: Set -> PhaseM LoopState l ()
notifyMero setEvent = do
  phaseLog "action" $ "Sending configuration update to mero services: "
                   ++ show setEvent
  chans <- getNotificationChannels
  forM_ chans $ \(sp, recipients) -> liftProcess $
      sendChan sp $ NotificationMessage setEvent recipients []

lookupMeroChannelByNode :: Node -> PhaseM LoopState l (Maybe (TypedChannel NotificationMessage))
lookupMeroChannelByNode node = do
   rg <- getLocalGraph
   let mlchan = listToMaybe
         [ chan | sp   <- G.connectedTo node Runs rg :: [ServiceProcess MeroConf]
                , chan <- G.connectedTo sp MeroChannel rg ]
   return mlchan
