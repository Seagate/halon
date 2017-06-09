{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Module    : HA.Services.Mero
-- Copyright : (C) 2013 Xyratex Technology Limited.
--                 2015-2017 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.Services.Mero
    ( InternalStarted(..)
    , MeroConf(..)
    , MeroFromSvc(..)
    , MeroKernelConf(..)
    , MeroToSvc(..)
    , NotificationMessage(..)
    , ProcessConfig(..)
    , ProcessControlMsg(..)
    , ProcessControlStartResult(..)
    , ProcessRunType(..)
    , HA.Services.Mero.Types.__remoteTable
    , HA.Services.Mero.__remoteTableDecl
    , HA.Services.Mero.__resourcesTable
    , Mero.Notification.getM0Worker
    , confXCPath
    , lookupM0d
    , m0d__static
    , m0d_real
    , putM0d
    , traceM0d
    , unitString
    ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure ( remotableDecl, mkStatic, mkStaticClosure )
import qualified Control.Distributed.Process.Internal.Types as DI
import           Control.Distributed.Static (staticApply)
import           Control.Exception (SomeException, IOException)
import           Control.Monad (forever, unless, void, when)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.Trans.Reader
import qualified Data.Bimap as BM
import           Data.Binary
import qualified Data.ByteString as BS
import           Data.Char (toUpper)
import           Data.Maybe (maybeToList)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import           HA.Debug
import           HA.Logger
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import           HA.Service
import           HA.Service.Interface
import           HA.Services.Mero.Types
import           Mero.ConfC (Fid, fidToStr)
import           Mero.Lnet
import qualified Mero.Notification
import           Mero.Notification (NIRef)
import           Mero.Notification.HAState
import qualified Network.RPC.RPCLite as RPC
import           System.Directory
import           System.Exit
import           System.FilePath
import qualified System.Posix.Process as Posix
import           System.Process
import qualified System.SystemD.API as SystemD
import qualified System.Timeout as ST

__resourcesTable :: RemoteTable -> RemoteTable
__resourcesTable = HA.Services.Mero.Types.myResourcesTable

-- | Tracer for @halon:m0d@ with value @"halon:m0d"@. See 'mkHalonTracer'.
traceM0d :: String -> Process ()
traceM0d = mkHalonTracer "halon:m0d"

-- | Process handling object status updates: it dispatches
-- notifications ('NotificationMessage') to local mero processes.
statusProcess :: NIRef
              -> Fid -- ^ HA process 'Fid'
              -> Fid -- ^ HA service 'Fid'
              -> ProcessId
              -> ReceivePort NotificationMessage
              -> Process ()
statusProcess niRef ha_pfid ha_sfid pid rp = do
    -- TODO: When mero can handle exceptions caught here, report them to the RC.
    link pid
    forever $ do
      msg@(NotificationMessage epoch set ps) <- receiveChan rp
      traceM0d $ "statusProcess: notification msg received: " ++ show msg
      -- We recreate process, this is highly unsafe and it's not allowed
      -- to do receive read calls. also this thread will not be killed when
      -- status process is killed.
      lproc <- DI.Process ask
      Mero.Notification.notifyMero niRef ps set ha_pfid ha_sfid
            (\fid -> DI.runLocalProcess lproc $ do
              traceM0d $ "Sending notification ack for fid " ++ show fid
                      ++ " in epoch " ++ show epoch
              uuid <- sendRC interface $ NotificationAck epoch fid
              traceM0d $ "Sent notification ack for fid " ++ show fid
                      ++ " in epoch " ++ show epoch ++ " (" ++ show uuid ++ ")"
            )
            (\fid -> DI.runLocalProcess lproc $ do
              traceM0d $ "Sending notification failure for fid " ++ show fid
                      ++ " in epoch " ++ show epoch
              void . sendRC interface $ NotificationFailure epoch fid)
   `catchExit` (\_ reason -> traceM0d $ "statusProcess exiting: " ++ reason)
   `Catch.catch` \(e :: SomeException) -> do
      traceM0d $ "statusProcess terminated: " ++ show (pid, e)
      Catch.throwM e

-- | Run keep-alive when channel receives a message to do so
keepaliveProcess :: Int -- ^ Keepalive frequency (seconds)
                 -> Int -- ^ Keepalive timeout (seconds)
                 -> Fid -- ^ HA process 'Fid'
                 -> Fid -- ^ HA service 'Fid'
                 -> NIRef
                 -> ProcessId -- ^ Caller process (for 'link')
                 -> Process ()
keepaliveProcess kaFreq kaTimeout ha_pfid ha_sfid niRef pid = do
  link pid
  forever $ do
    _ <- receiveTimeout (kaFreq * 1000000) []
    pruned <- liftIO $ Mero.Notification.pruneLinks niRef kaTimeout
    liftIO $ Mero.Notification.runPing niRef ha_pfid ha_sfid
    unless (null pruned) $ do
      sendRC interface $ KeepaliveTimedOut pruned

-- | Process responsible for controlling the system level Mero
-- processes running on this node.
--
-- Only one command for each value of 'ProcessControlMsg' is ran at a
-- time. That is, sending the same command to the control process will
-- have no effect if we don't have a result from previous run yet.
--
-- Notes:
--
-- * 'usend' does not solve a problem of sending potentially stale
--   replies to the RC. Unless the service itself dies, RC can happily
--   restart before the reply is sent, 'usend' happens, RC gets stale
--   information and we have the same issue as in HALON-635.
--
-- * UUID is used in messages that we do not want to possibly
--   duplicate. This is only needed for configuration currently: stop
--   and start messages are tagged with PID and duplicating these will
--   not harm us.
--
-- * Unfortunately tagging configure message with UUID means that
--   same-command filtering mechanism no longer works. If we want to
--   avoid potentially running multiple mkfs commands concurrently, we
--   have 3 options, only first of which seem acceptable:
--
--     * Only allow single mkfs to run at once. When it completes,
--       send the result as a reply to any requests that have come in
--       while it was running. This should be OK as only single rule
--       invocation will care about one of the replies.
--
--     * Only send the reply to latest configure request that came in.
--       This is unreliable because last message service receives does
--       not mean it's the message from currently invoked rule.
--
--     * Queue configure requests and execute them sequentially,
--       replying to each one with the result. This prevents
--       concurrent mkfs runs but means we can have multiple mkfs
--       invocations. In principle this should be OK but beyond being
--       a waste of time and resources, many queued up requests could
--       make recovery difficult to perform without waiting it out.
--       Worse, it can result in HALON-635 if message reordering
--       happens.
controlProcess :: MeroConf
               -> ProcessId -- ^ Parent process to link to
               -> ReceivePort ProcessControlMsg
               -> Process ()
controlProcess mc pid rp = do
  link pid
  master <- getSelfPid
  let loop slaves = receiveWait
        [ matchIf (\(ProcessMonitorNotification mref _ _) -> BM.member mref slaves)
                  (\(ProcessMonitorNotification mref _ _) ->
                     unmonitor mref >> loop (BM.delete mref slaves))
        , matchChan rp $ \m -> do
            when (m `BM.memberR` slaves) $ do
              say $ "controlProcess: (" ++ show m ++ ") already running, doing nothing."
              loop slaves

            let forkIOInProcess act onResult = do
                  slave <- spawnLocal $ link master >> liftIO act >>= onResult
                  mref <- monitor slave
                  loop $ BM.insert mref m slaves
            nid <- getSelfNode
            case m of
              ConfigureProcess runType conf env mkfs uid -> forkIOInProcess
                (configureProcess mc runType conf env mkfs)
                (sendRC interface . ProcessControlResultConfigureMsg uid)
              StartProcess runType p -> forkIOInProcess
                (startProcess runType p)
                (sendRC interface . ProcessControlResultMsg)
              StopProcess runType p -> forkIOInProcess
                (stopProcess runType p)
                (sendRC interface . ProcessControlResultStopMsg nid)
              DixInit imeta -> forkIOInProcess
                (dixInit mc imeta)
                (sendRC interface . DixInitialised)

        ]
  loop BM.empty

--------------------------------------------------------------------------------
-- Mero Process control
--------------------------------------------------------------------------------

-- | Default path for @conf.xc@: "/var/mero/confd/conf.xc".
confXCPath :: FilePath
confXCPath = "/var/mero/confd/conf.xc"

-- | Create configuration for service and run mkfs if requested.
configureProcess :: MeroConf        -- ^ Mero configuration.
                 -> ProcessRunType  -- ^ Run type of the process.
                 -> ProcessConfig   -- ^ Process configuration.
                 -> [M0.ProcessEnv]    -- ^ Additional environment
                 -> Bool            -- ^ Is mkfs needed?
                 -> IO (Either (M0.Process, String) M0.Process)
configureProcess mc run conf env needsMkfs = do
  let procFid = M0.fid p
  putStrLn $ "m0d: configureProcess: " ++ show procFid
           ++ " with type(s) " ++ show run
  confXC <- maybeWriteConfXC conf
  _unit  <- writeSysconfig mc run procFid
                            (T.unpack . encodeEndpoint $ M0.r_endpoint p)
                            confXC (toEnv <$> env)
  if needsMkfs
  then do
    ec <- SystemD.startService $ "mero-mkfs@" ++ fidToStr procFid
    return $ case ec of
      Right _ -> Right p
      Left x -> Left (p, "Unit failed to start with exit code " ++ show x)
  else return $ Right p
  where
    toEnv (M0.ProcessEnvValue key val) = (key, val)
    toEnv (M0.ProcessEnvInRange key val) = (key, show val)
    maybeWriteConfXC (ProcessConfigLocal _ bs) = do
      liftIO $ writeConfXC bs
      return $ Just confXCPath
    maybeWriteConfXC _ = return Nothing
    p = case conf of
      ProcessConfigLocal p' _ -> p'
      ProcessConfigRemote p' -> p'

-- | Check the status of m0d service and possibly start it.
--
-- The service is only started if @systemctl status@ doesn't say it's
-- already running. If it's running, 'RequiresStop' is returned.
startProcess :: ProcessRunType -- ^ Run type of the process.
             -> M0.Process     -- ^ Process itself.
             -> IO ProcessControlStartResult
startProcess run p = do
  let svc = unitString run p
  do SystemD.statusService (unitString run p) >>= \case
       -- Service running
       ExitSuccess -> return $! RequiresStop p
       -- All other failures should indicate some sort of
       -- dead/inexistent service: try to start it and just report the
       -- issue from there.
       _ -> do
         putStrLn $ "m0d: startProcess: " ++ fidToStr (M0.fid p) ++ " with type(s) " ++ show run
         -- Now that we check service status, use
         -- 'SystemD.startService' and not restart: this way we'll
         -- know sooner if we have some bugs with stop still instead
         -- of hiding them.
         --
         -- TODO: For an actual release it might be smarter to restart
         -- still; probably better to do restart in some weird case
         -- than not permit start at all.
         SystemD.startService svc >>= return . \case
           Right (Just pid) -> Started p pid
           Right Nothing -> StartFailure p "Service started but no PID found."
           Left rc -> StartFailure p ("Unit failed to start with exit code " ++ show rc)
  `Catch.catch` \e -> do
    return . StartFailure p $ show (e :: Catch.SomeException)

-- | Stop mero process.
--
-- The @systemctl@ stop command is given 60 seconds to run after which
-- point we assume and report failure for action.
stopProcess :: ProcessRunType        -- ^ Type of the process.
            -> M0.Process            -- ^ 'M0.Process' to stop.
            -> IO (Either (M0.Process, String) M0.Process)
stopProcess run p = flip Catch.catch handler $ do
  let unit = unitString run p
  putStrLn $ "m0d: stopProcess: " ++ unit ++ " with type(s) " ++ show run
  ec <- ST.timeout ptimeout $ SystemD.stopService unit
  case ec of
    Nothing -> do
      putStrLn $ unwords [ "m0d: stopProcess timed out after", show ptimeoutSec, "s for", show unit ]
      return $ Left (p, "Failed to stop after " ++ show ptimeoutSec ++ "s")
    Just ExitSuccess -> do
      putStrLn $ "m0d: stopProcess OK for " ++ show unit
      return $ Right p
    Just (ExitFailure x) -> do
      putStrLn $ "m0d: stopProcess failed."
      return $ Left (p, "Unit failed to stop with exit code " ++ show x)
  where
    handler e = return $ Left (p, show (e :: Catch.SomeException))
    ptimeoutSec = 60
    ptimeout = ptimeoutSec * 1000000

-- | Call `m0dixinit` to initialise KVS system on the cluster.
dixInit :: MeroConf
        -> Fid -- ^ imeta_pver
        -> IO (Either String ())
dixInit mc imeta = do
    (ec, _, err) <- readProcessWithExitCode "m0dixinit" args ""
    case ec of
      ExitSuccess -> return $ Right ()
      ExitFailure _ -> return $ Left err
  where
    args =
      [ "-l", localEP
      , "-H", mcHAAddress mc
      , "-I", fidToStr imeta
      , "-d", fidToStr imeta
      , "-p", fidToStr (mcProfile mc)
      , "-a", "create"
      ]
    localEP = takeWhile (/= '@') (mcHAAddress mc) ++ dixEP
    dixEP = "@tcp:12345:34:102"

-- | Convert a process run type and 'Fid' to the corresponding systemd
-- service string.
unitString :: ProcessRunType       -- ^ Type of the process.
           -> M0.Process           -- ^ Process.
           -> String
unitString run p = case run of
  M0T1FS -> "m0t1fs@" ++ fidToStr (M0.fid p) ++ ".service"
  M0D -> "m0d@" ++ fidToStr (M0.fid p)  ++ ".service"
  CLOVIS s -> s ++ "@" ++ fidToStr (M0.fid p) ++ ".service"

-- | Write out the @conf.xc@ file for a confd server. See also
-- 'confXCPath'. Creates parent directories if missing.
writeConfXC :: BS.ByteString -- ^ Contents of @conf.xc@ file
            -> IO ()
writeConfXC conf = do
  createDirectoryIfMissing True $ takeDirectory confXCPath
  BS.writeFile confXCPath conf

-- | Write out systemd sysconfig file appropriate to process. Returns
-- the unit name of the corresponding unit to start. Part of process
-- configuration procedure.
writeSysconfig :: MeroConf
               -- ^ Configuration of @halon:m0d@ service, necessary
               -- for the information required by soon-to-be-started
               -- process.
               -> ProcessRunType
               -> Fid -- ^ Process fid
               -> String -- ^ Endpoint address
               -> Maybe String -- ^ Confd address?
               -> [(String, String)] -- ^ Additional environment values
               -> IO String
writeSysconfig MeroConf{..} run procFid m0addr confdPath additionalEnv = do
    putStrLn $ "m0d: Writing sysctlFile: " ++ fileName
    _ <- SystemD.sysctlFile fileName $
      [ ("MERO_" ++ fmap toUpper prefix ++ "_EP", m0addr)
      , ("MERO_HA_EP", mcHAAddress)
      , ("MERO_PROFILE_FID", fidToStr mcProfile)
      , ("MERO_PROCESS_FID", fidToStr procFid)
      ] ++ maybeToList (("MERO_CONF_XC",) <$> confdPath)
        ++ additionalEnv
    return unit
  where
    fileName = prefix ++ "-" ++ fidToStr procFid
    (prefix, unit) = case run of
      M0T1FS -> ("m0t1fs", "m0t1fs@")
      M0D -> ("m0d", "m0d@")
      CLOVIS s -> (s, s ++ "@")

-- | The @halon:m0d@ service has started.
newtype InternalStarted =
  InternalStarted (SendPort NotificationMessage,SendPort ProcessControlMsg)
  -- ^ @Started (notificationHandlerChan, processControlChan)@
  deriving (Eq, Show, Binary)

m0dProcess :: ProcessId -> MeroConf -> Process ()
m0dProcess parent conf = do
  traceM0d "starting."
  Catch.bracket startKernel (\_ -> stopKernel) $ \rc -> do
    traceM0d "Kernel module loaded."
    case rc of
      Right _ -> do
        self <- getSelfPid
        flip Catch.catch epHandler . withEp $ \ep -> do
          traceM0d "Starting helper processes and initialising channels."
          _ <- spawnLocal $ keepaliveProcess (mcKeepaliveFrequency conf)
                                             (mcKeepaliveTimeout conf)
                                             processFid haFid ep self
          c <- spawnChannelLocal $ statusProcess ep processFid haFid self
          cc <- spawnChannelLocal $ controlProcess conf self
          usend parent (InternalStarted (c,cc))
          traceM0d "Started service m0d on mero client"
          -- Block forever, keeping the endpoint open.
          receiveWait []
      Left i -> do
        traceM0d $ "Kernel module did not load correctly: " ++ show i
        sendRC interface . MeroKernelFailed (processNodeId parent) $
          "mero-kernel service failed to start: " ++ show i
        Control.Distributed.Process.die Shutdown
  where
    profileFid = mcProfile conf
    processFid = mcProcess conf
    rmFid      = mcRM      conf
    haFid      = mcHA      conf
    haAddr = RPC.rpcAddress $ mcHAAddress conf
    withEp = Mero.Notification.withMero
           . Mero.Notification.withNI haAddr processFid profileFid haFid rmFid

    epHandler :: IOException -> Process ()
    epHandler e = do
      let msg = "endpoint exception in halon:m0d: " ++ show e
      say $ "[service:m0d] " ++ msg
      sendRC interface . MeroKernelFailed (processNodeId parent) $ msg

    -- Kernel
    startKernel = liftIO $ do
      _ <- SystemD.sysctlFile "mero-kernel"
        [ ("MERO_NODE_UUID", UUID.toString $ mkcNodeUUID (mcKernelConfig conf))
        ]
      SystemD.startService "mero-kernel"
    stopKernel =
       receiveTimeout 2000000 [] `Catch.finally` liftIO (void $ SystemD.stopService "mero-kernel")

remotableDecl [ [d|
  m0d :: Service MeroConf
  m0d = Service "m0d"
          $(mkStaticClosure 'm0dFunctions)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictMeroConf))

  m0dFunctions :: ServiceFunctions MeroConf
  m0dFunctions = ServiceFunctions bootstrap mainloop teardown confirm where
    bootstrap conf = do
      self <- getSelfPid
      sendRC interface $! CheckCleanup (processNodeId self)
      cleanup <- receiveTimeout (10 * 1000000)
        [ receiveSvcIf interface
            (\case Cleanup{} -> True
                   _ -> False)
            (\case Cleanup b -> return b
                   -- ‘impossible’
                   _ -> return False) ]
      case cleanup of
        Just True -> liftIO (SystemD.startService "mero-cleanup") >>= \case
          Right _ -> return ()
          Left i -> do
            traceM0d $ "mero-cleanup did not run correctly: " ++ show i
            sendRC interface . MeroCleanupFailed (processNodeId self) $
              "mero-cleanup service failed to start: " ++ show i
            Control.Distributed.Process.die Shutdown
        Just False -> traceM0d "mero-cleanup not required."
        Nothing ->
          -- This case is pretty unusual. Means some kind of major failure of
          -- the RC. Regardless, we continue, since at worst we just fail on
          -- the next step instead.
          traceM0d "Could not ascertain whether to run mero-cleanup."
      pid <- spawnLocalName "service::m0d::process" $ do
        link self
        m0dProcess self conf
      monitor pid
      receiveWait
        [ matchIf (\(ProcessMonitorNotification _ p _) -> pid == p)
                $ \_ -> do
          sendRC interface . MeroKernelFailed (processNodeId self) $ "process exited."
          return (Left "failure during start")
        , match $ \(InternalStarted (c,cc)) -> do
          return (Right (pid,c,cc))
        ]
    mainloop conf s@(pid,c,cc) = do
      self <- getSelfPid
      return [ matchIf (\(ProcessMonitorNotification _ p _) -> pid == p)
                   $ \_ -> do
                 sendRC interface . MeroKernelFailed (processNodeId self) $ "process exited."
                 return (Failure, s)
             , receiveSvc interface $ \case
                 PerformNotification nm -> do
                   sendChan c nm
                   return (Continue, s)
                 ProcessMsg pm -> do
                   sendChan cc pm
                   return (Continue, s)
                 AnnounceYourself -> do
                   traceM0d $ "Announcing STARTED, likely due to node recovery."
                   sys_pid <- liftIO $ fromIntegral <$> Posix.getProcessID
                   t <- liftIO m0_time_now
                   let meta = HAMsgMeta { _hm_fid = mcProcess conf
                                        , _hm_source_process = mcProcess conf
                                        , _hm_source_service = mcHA conf
                                        , _hm_time = t }
                       evt = ProcessEvent { _chp_event = TAG_M0_CONF_HA_PROCESS_STARTED
                                          , _chp_type = TAG_M0_CONF_HA_PROCESS_M0D
                                          , _chp_pid = sys_pid }
                   sendRC interface . AnnounceEvent $ HAMsg evt meta
                   return (Continue, s)
                 m -> do
                   traceM0d $ "Unprocessed message: " ++ show m
                   return (Continue, s)
             , match $ \(InternalServiceReconnectReply c' cc') -> do
                 return (Continue, (pid, c', cc'))
             ]
    teardown _ (pid,_,_) = do
      mref <- monitor pid
      exit pid "teardown"
      receiveWait
        [ matchIf (\(ProcessMonitorNotification m _ _) -> mref == m)
                  $ \_ -> return ()
        ]
    confirm  _ _ = return ()
    |] ]


-- | Find the @'Service' 'MeroConf'@ instance that should be used. By
-- default, 'm0d' is provided if no value.
lookupM0d :: G.Graph -> Service MeroConf
lookupM0d = maybe m0d _msi_m0d . G.connectedTo R.Cluster R.Has

-- | Register the given @'Service' 'MeroConf'@ as the @halon:m0d@
-- service to use when requested. This allows us to replace the
-- default implementation by, for example, a mock.
--
-- This should only be used before any @halon:m0d@ service is started
-- and should not be changed afterwards as to not confuse rules or
-- even start two separate services.
putM0d :: Service MeroConf -> G.Graph -> G.Graph
putM0d m = G.connect R.Cluster R.Has (MeroServiceInstance m)

-- | Alias for 'm0d'. Represents a "real" @halon:m0d@ service. It
-- shouldn't be used directly unless you know what you're doing. Use
-- 'lookupM0d' instead.
--
-- Use-sites:
--
-- - @halonctl@
m0d_real :: Service MeroConf
m0d_real = m0d
