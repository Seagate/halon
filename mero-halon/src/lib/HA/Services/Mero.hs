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
{-# LANGUAGE ViewPatterns          #-}

module HA.Services.Mero
    ( MeroChannel(..)
    , TypedChannel(..)
    , DeclareMeroChannel(..)
    , MeroChannelDeclared(..)
    , NotificationMessage(..)
    , ProcessRunType(..)
    , ProcessConfig(..)
    , ProcessControlMsg(..)
    , ProcessControlResultMsg(..)
    , ProcessControlResultStopMsg(..)
    , MeroConf(..)
    , MeroKernelConf(..)
    , m0d
    , meroServiceName
    , HA.Services.Mero.__remoteTableDecl
    , HA.Services.Mero.Types.__remoteTable
    , m0dProcess__sdict
    , m0dProcess__tdict
    , m0d__static
    , meroRules
    , createSet
    , notifyMero
    , notifyMeroAndThen
    , lookupMeroChannelByNode
    ) where

import HA.Logger
import HA.EventQueue.Producer (expiate, promulgate, promulgateWait)
import HA.RecoveryCoordinator.Actions.Core
import qualified HA.RecoveryCoordinator.Events.Mero as M0
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState(..), NotifyFailureEndpoints(..))
import HA.Service
import HA.Services.Mero.CEP (meroRulesF)
import HA.Services.Mero.Types
import qualified HA.ResourceGraph as G

import qualified Mero.Notification
import Mero.Notification (Set(..), NIRef)
import Mero.Notification.HAState (Note(..))
import Mero.ConfC (Fid, ServiceType(..), fidToStr)

import Network.CEP
import qualified Network.RPC.RPCLite as RPC

import Control.Monad (unless)
import Control.Monad.Fix (fix)
import Control.Monad.Trans.Reader
import Control.Exception (SomeException)
import qualified Control.Distributed.Process.Internal.Types as DI
import Control.Distributed.Process.Closure
  ( remotableDecl
  , mkStatic
  , mkStaticClosure
  )
import Control.Distributed.Static
  ( staticApply )
import Control.Distributed.Process hiding (catch, bracket_)
import Control.Monad.Catch (catch, bracket_)
import Control.Monad (forever, void)
import qualified Control.Monad.Catch as Catch

import qualified Data.ByteString as BS
import Data.Char (toUpper)
import Data.Foldable (for_)
import Data.Traversable (forM)
import Data.List (partition)
import Data.Maybe (catMaybes, listToMaybe, maybeToList)
import qualified Data.Set as Set
import qualified Data.UUID as UUID

import System.Exit
import System.FilePath
import System.Directory
import qualified System.SystemD.API as SystemD
import qualified System.Timeout as ST

traceM0d :: String -> Process ()
traceM0d = mkHalonTracer "halon:m0d"

-- | Store information about communication channel in resource graph.
sendMeroChannel :: SendPort NotificationMessage
                -> SendPort ProcessControlMsg
                -> Process ()
sendMeroChannel cn cc = do
  pid <- getSelfPid
  let chan = DeclareMeroChannel
              (ServiceProcess pid) (TypedChannel cn) (TypedChannel cc)
  void $ promulgate chan

statusProcess :: NIRef
              -> ProcessId
              -> ReceivePort NotificationMessage
              -> Process ()
statusProcess niRef pid rp = do
    -- TODO: When mero can handle exceptions caught here, report them to the RC.
    link pid
    forever $ do
      msg@(NotificationMessage set _ subs) <- receiveChan rp
      traceM0d $ "statusProcess: notification msg received: " ++ show msg
      -- We crecreate process, this is highly unsafe and it's not allowed
      -- to do receive read calls. also this thread will not be killed when
      -- status process is killed.
      lproc <- DI.Process ask
      Mero.Notification.notifyMero niRef set
            (DI.runLocalProcess lproc $ for_ subs $ flip usend $ NotificationAck ())
            (DI.runLocalProcess lproc $ for_ subs $ flip usend $ NotifyFailureEndpoints [])
   `catch` \(e :: SomeException) -> do
      traceM0d $ "statusProcess terminated: " ++ show (pid, e)
      Catch.throwM e

-- | Run keep-alive when channel receives a message to do so
keepaliveProcess :: Int -- ^ Keepalive frequency (seconds)
                 -> Int -- ^ Keepalive timeout (seconds)
                 -> NIRef
                 -> ProcessId
                 -> Process ()
keepaliveProcess kaFreq kaTimeout niRef pid = do
  link pid
  forever $ do
    _ <- receiveTimeout (kaFreq * 1000000) []
    pruned <- liftIO $ Mero.Notification.pruneLinks niRef kaTimeout
    liftIO $ Mero.Notification.runPing niRef
    unless (null pruned) $ do
      promulgateWait $ KeepaliveTimedOut pruned

-- | Process responsible for controlling the system level
--   Mero processes running on this node.
controlProcess :: MeroConf
               -> ProcessId -- ^ Parent process to link to
               -> ReceivePort ProcessControlMsg
               -> Process ()
controlProcess mc pid rp = link pid >> (forever $ receiveChan rp >>= \case
    ConfigureProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ mapM (\(a,b,c) -> configureProcess mc a b c) procs
      promulgateWait $ ProcessControlResultConfigureMsg nid results
    StartProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ mapM (uncurry startProcess) procs
      promulgateWait $ ProcessControlResultMsg nid results
    StopProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ mapM (uncurry stopProcess) procs
      promulgateWait $ ProcessControlResultStopMsg nid results
    RestartProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ mapM (uncurry restartProcess) procs
      promulgateWait $ ProcessControlResultRestartMsg nid results
  )

--------------------------------------------------------------------------------
-- Mero Process control
--------------------------------------------------------------------------------

confXCPath :: FilePath
confXCPath = "/var/mero/confd/conf.xc"

-- | Create configuration for service and run mkfs.
configureProcess :: MeroConf        -- ^ Mero configuration.
                 -> ProcessRunType  -- ^ Type of the process.
                 -> ProcessConfig   -- ^ Process configuration.
                 -> Bool            -- ^ Is mkfs needed.
                 -> IO (Either Fid (Fid,String))
configureProcess mc run conf needsMkfs = do
  putStrLn $ "m0d: configureProcess: " ++ show procFid
           ++ " with type(s) " ++ show run
  confXC <- maybeWriteConfXC conf
  _unit  <- writeSysconfig mc run procFid m0addr confXC
  if needsMkfs
  then do
    ec <- SystemD.startService $ "mero-mkfs@" ++ fidToStr procFid
    return $ case ec of
      ExitSuccess -> Left procFid
      ExitFailure x -> Right (procFid, "Unit failed to start with exit code " ++ show x)
  else return $ Left procFid
  where
    maybeWriteConfXC (ProcessConfigLocal _ _ bs) = do
      liftIO $ writeConfXC bs
      return $ Just confXCPath
    maybeWriteConfXC _ = return Nothing
    (procFid, m0addr) = getProcFidAndEndpoint conf

-- | Start mero process.
startProcess :: ProcessRunType   -- ^ Type of the process.
             -> Fid              -- ^ Process Fid.
             -> IO (Either Fid (Fid, String))
startProcess run fid = flip Catch.catch (generalProcFailureHandler fid) $ do
    putStrLn $ "m0d: startProcess: " ++ show fid ++ " with type(s) " ++ show run
    ec <- SystemD.startService $ unitString run fid
    return $ case ec of
      ExitSuccess -> Left fid
      ExitFailure x ->
        Right (fid, "Unit failed to start with exit code " ++ show x)

-- | Restart mero process.
restartProcess :: ProcessRunType     -- ^ Type of the process.
               -> Fid                -- ^ Process Fid.
               -> IO (Either Fid (Fid,String))
restartProcess run fid = flip Catch.catch (generalProcFailureHandler fid) $ do
  let unit = unitString run fid
  putStrLn $ "m0d: restartProcess: " ++ unit ++ " with type(s) " ++ show run
  ec <- SystemD.restartService unit
  case ec of
    ExitSuccess -> return $ Left fid
    ExitFailure x -> do
      putStrLn $ "m0d: restartProcess failed."
      return $ Right (fid, "Unit failed to restart with exit code " ++ show x)

-- | Stop running mero service.
stopProcess :: ProcessRunType        -- ^ Type of the process.
            -> Fid                   -- ^ Process Fid.
            -> IO (Either Fid (Fid,String))
stopProcess run fid = flip Catch.catch (generalProcFailureHandler fid) $ do
  let unit = unitString run fid
  putStrLn $ "m0d: stopProcess: " ++ unit ++ " with type(s) " ++ show run
  ec <- ST.timeout ptimeout $ SystemD.stopService unit
  case ec of
    Nothing -> do
      putStrLn $ unwords [ "m0d: stopProcess timed out after", show ptimeoutSec, "s for", show unit ]
      return $ Right (fid, "Failed to stop after " ++ show ptimeoutSec ++ "s")
    Just ExitSuccess -> do
      putStrLn $ "m0d: stopProcess OK for " ++ show unit
      return $ Left fid
    Just (ExitFailure x) -> do
      putStrLn $ "m0d: stopProcess failed."
      return $ Right (fid, "Unit failed to stop with exit code " ++ show x)
  where
    ptimeoutSec = 60
    ptimeout = ptimeoutSec * 1000000

-- | Generate unit file name.
unitString :: ProcessRunType       -- ^ Type of the process.
           -> Fid                  -- ^ Process Fid.
           -> String
unitString run fid = case run of
  M0T1FS -> "m0t1fs@" ++ fidToStr fid ++ ".service"
  M0D -> "m0d@" ++ fidToStr fid ++ ".service"

-- | Get the process fid and endpoint from the given 'MeroConf'.
getProcFidAndEndpoint :: ProcessConfig -> (Fid, String)
getProcFidAndEndpoint (ProcessConfigLocal x y _) = (x, y)
getProcFidAndEndpoint (ProcessConfigRemote x y) = (x, y)

-- | General failure handler for the process start/stop/restart actions.
generalProcFailureHandler :: Fid -> Catch.SomeException
                          -> IO (Either Fid (Fid, String))
generalProcFailureHandler fid e = return $ Right (fid, show e)

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
      , ("MERO_PROFILE_FID", fidToStr mcProfile)
      ] ++ maybeToList (("MERO_CONF_XC",) <$> confdPath)
    return unit
  where
    fileName = prefix ++ "-" ++ fidToStr procFid
    (prefix, unit) = case run of
      M0T1FS -> ("m0t1fs", "m0t1fs@")
      M0D -> ("m0d", "m0d@")

remotableDecl [ [d|

  m0d :: Service MeroConf
  m0d = Service
          meroServiceName
          $(mkStaticClosure 'm0dProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictMeroConf))

  m0dProcess :: MeroConf -> Process ()
  m0dProcess conf = do
    traceM0d "starting."
    Catch.bracket startKernel (\_ -> stopKernel) $ \rc -> do
      traceM0d "Kernel module loaded."
      case rc of
        ExitSuccess -> bracket_ bootstrap teardown $ do
          self <- getSelfPid
          traceM0d "DEBUG: Pre-withEp"
          c <- withEp $ \ep -> do
            _ <- spawnLocal $ keepaliveProcess (mcKeepaliveFrequency conf)
                                               (mcKeepaliveTimeout conf) ep self
            spawnChannelLocal (statusProcess ep self)
          traceM0d "DEBUG: Pre-withEp"
          cc <- spawnChannelLocal (controlProcess conf self)
          sendMeroChannel c cc

          traceM0d "Starting service m0d on mero client"
          go
        ExitFailure i -> do
          self <- getSelfPid
          traceM0d $ "Kernel module did not load correctly: " ++ show i
          void . promulgate . M0.MeroKernelFailed self $
            "mero-kernel service failed to start: " ++ show i
    where
      profileFid = mcProfile conf
      processFid = mcProcess conf
      haAddr = RPC.rpcAddress $ mcHAAddress conf
      withEp = Mero.Notification.withNI haAddr processFid profileFid

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
        traceM0d "DEBUG: Pre-initialize"
        Mero.Notification.initialize haAddr processFid profileFid
        traceM0d "DEBUG: Post-initialize"
      teardown = do
        traceM0d "DEBUG: Pre-finalize"
        Mero.Notification.finalize
        traceM0d "DEBUG: Post-finalize"

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
  let nodes = [ (node, m0node)
              | host <- G.connectedTo Cluster Has rg :: [Host]
              , node <- G.connectedTo host Runs rg :: [Node]
              , m0node <- G.connectedTo host Runs rg :: [M0.Node]
              ]

  things <- forM nodes $ \(node, m0node) -> do
     mchan <- lookupMeroChannelByNode node
     let recipients = Set.fromList (fst <$> nha) Set.\\ Set.fromList (fst <$> ha)
         (nha, ha) = partition ((/=) CST_HA . snd)
                   [ (endpoint, stype)
                   | m0proc <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
                   , G.isConnected m0proc Is M0.PSOnline rg
                   , service <- G.connectedTo m0proc M0.IsParentOf rg :: [M0.Service]
                   , let stype = M0.s_type service
                   , endpoint <- M0.s_endpoints service
                   ]

     case (mchan, recipients) of
       (_, x) | Set.null x -> return Nothing
       (Nothing, Set.toList -> r) -> do
         localNode <- liftProcess getSelfNode
         lookupMeroChannelByNode (Node localNode) >>= \case
            Just (TypedChannel chan) -> do
               phaseLog "warning" $ "HA.Service.Mero.notifyMero: can't find remote service for"
                                  ++ show node
                                  ++ ", sending from local. "
                                  ++ "Recipients: "
                                  ++ show r
               return $ Just (chan, r)
            Nothing -> do
              phaseLog "error" $ "HA.Service.Mero.notifyMero: cannot notify MeroChannel on "
                              ++ show (node, localNode)
                              ++ " nor local channel. "
                              ++ "Recipients: "
                              ++ show r
              return Nothing
       (Just (TypedChannel chan), Set.toList -> r) -> return $ Just (chan, r)
  return $ catMaybes things

-- | Create a set event from a set of conf objects and a state.
--   TODO: This is only temporary until we move to `stateSet`
createSet :: [M0.AnyConfObj] -> ConfObjectState -> Set
createSet cs st = setEvent
  where
    getFid (M0.AnyConfObj a) = M0.fid a
    setEvent :: Mero.Notification.Set
    setEvent = Mero.Notification.Set $ map (flip Note st . getFid) cs

notifyMeroAndThen :: Set
                  -> Process () -- ^ Action on success
                  -> Process () -- ^ Action on failure
                  -> PhaseM LoopState l ()
notifyMeroAndThen setEvent fsucc ffail = do
    phaseLog "action" $ "Sending configuration update to mero services: "
                     ++ show setEvent
    chans <- getNotificationChannels
    liftProcess $ do
      self <- getSelfPid
      void $ spawnLocal $ do
        link self
        sendChansBlocking chans
  where
    -- Send a message to all channels and block until each has replied
    sendChansBlocking :: [(SendPort NotificationMessage, [String])] -> Process ()
    sendChansBlocking [] = fsucc
    sendChansBlocking chans = do
      selfLocal <- getSelfPid
      for_ chans $ \(chan, recipients) ->
        sendChan chan $ NotificationMessage setEvent recipients [selfLocal]
      fix (\loop i -> receiveWait
          [ match $ \NotificationAck{} -> do
             if i <= 1
             then fsucc
             else loop (i-1)
          , match $ \NotifyFailureEndpoints{} -> ffail
          ]) (length chans)

notifyMero :: Set -> PhaseM LoopState l ()
notifyMero setEvent = do
  phaseLog "action" $ "Sending non-blocking configuration update to mero services: "
                   ++ show setEvent
  chans <- getNotificationChannels
  for_ chans $ \(sp, recipients) -> liftProcess $
      sendChan sp $ NotificationMessage setEvent recipients []

lookupMeroChannelByNode :: Node -> PhaseM LoopState l (Maybe (TypedChannel NotificationMessage))
lookupMeroChannelByNode node = do
   rg <- getLocalGraph
   let mlchan = listToMaybe
         [ chan | sp   <- G.connectedTo node Runs rg :: [ServiceProcess MeroConf]
                , chan <- G.connectedTo sp MeroChannel rg ]
   return mlchan
