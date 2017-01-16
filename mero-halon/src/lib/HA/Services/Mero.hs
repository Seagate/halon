{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Module    : HA.Services.Mero
-- Copyright : (C) 2013 Xyratex Technology Limited.
--                 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- TODO: Fix copyright header
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
    , ServiceStateRequest(..)
    , m0d_real
    , lookupM0d
    , putM0d
    , traceM0d
    , HA.Services.Mero.__remoteTableDecl
    , HA.Services.Mero.Types.__remoteTable
    , m0d__static
    , Mero.Notification.getM0Worker
    , sendMeroChannel
    , confXCPath
    , unitString
    , Started(..)
    ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure ( remotableDecl, mkStatic
                                                     , mkStaticClosure )
import qualified Control.Distributed.Process.Internal.Types as DI
import           Control.Distributed.Static (staticApply)
import           Control.Exception (SomeException, IOException)
import           Control.Monad (forever, unless, void, when)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.Trans.Reader
import           HA.Debug
import           HA.EventQueue (promulgate, promulgateWait)
import           HA.Logger
import qualified HA.RecoveryCoordinator.Mero.Events as M0
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import           HA.Service
import           HA.Services.Mero.RC.Events (CheckCleanup(..))
import           HA.Services.Mero.Types
import           Mero.ConfC (Fid, fidToStr)
import qualified Mero.Notification
import           Mero.Notification (NIRef)
import qualified Network.RPC.RPCLite as RPC
import qualified System.SystemD.API as SystemD

import           Data.Binary
import qualified Data.Bimap as BM
import qualified Data.ByteString as BS
import           Data.Char (toUpper)
import           Data.Maybe (maybeToList)
import qualified Data.UUID as UUID
import           System.Directory
import           System.Exit
import           System.FilePath
import qualified System.Timeout as ST

-- | Tracer for @halon:m0d@ with value @"halon:m0d"@. See 'mkHalonTracer'.
traceM0d :: String -> Process ()
traceM0d = mkHalonTracer "halon:m0d"

-- | Store information about communication channel in resource graph.
sendMeroChannel :: SendPort NotificationMessage
                -> SendPort ProcessControlMsg
                -> Process ()
sendMeroChannel cn cc = do
  pid <- getSelfPid
  let chan = DeclareMeroChannel
              pid (TypedChannel cn) (TypedChannel cc)
  void $ promulgate chan

statusProcess :: NIRef
              -> ProcessId
              -> ReceivePort NotificationMessage
              -> Process ()
statusProcess niRef pid rp = do
    -- TODO: When mero can handle exceptions caught here, report them to the RC.
    link pid
    forever $ do
      msg@(NotificationMessage epoch set ps) <- receiveChan rp
      traceM0d $ "statusProcess: notification msg received: " ++ show msg
      -- We crecreate process, this is highly unsafe and it's not allowed
      -- to do receive read calls. also this thread will not be killed when
      -- status process is killed.
      lproc <- DI.Process ask
      Mero.Notification.notifyMero niRef ps set
            (DI.runLocalProcess lproc . promulgateWait . NotificationAck epoch)
            (DI.runLocalProcess lproc . promulgateWait . NotificationFailure epoch)
   `Catch.catch` \(e :: SomeException) -> do
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

-- | Process responsible for controlling the system level Mero
-- processes running on this node.
--
-- Only one command for each value of 'ProcessControlMsg' is ran at a
-- time. That is, sending the same command to the control process will
-- have no effect if we don't have a result from previous run yet.
--
-- TODO: usend: RC restarts then we want probably *do* want to lose
-- these messages as the job that caused them is going to restart and
-- receiving old results isn't fun.
--
-- TODO2: tag these with UUID so that we know that we're getting the
-- right reply to the right message, then it won't matter either way
--
-- TODO2.5: really do TODO2; especially with stop, if we kill the
-- process through different means then old running command may become
-- unblocked and we may deliver old result! Or use some other solution
-- that kills old call when a new one comes in. This works assuming
-- jobs are only dispatchers of these control messages but also solves
-- TODO3.
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
              ConfigureProcess runType conf mkfs -> forkIOInProcess
                (configureProcess mc runType conf mkfs)
                (promulgateWait . ProcessControlResultConfigureMsg nid)
              StartProcess runType p -> forkIOInProcess
                (startProcess runType p)
                (promulgateWait . ProcessControlResultMsg nid)
              StopProcess runType p -> forkIOInProcess
                (stopProcess runType p)
                (promulgateWait . ProcessControlResultStopMsg nid)
        ]
  loop BM.empty

--------------------------------------------------------------------------------
-- Mero Process control
--------------------------------------------------------------------------------

-- | Default path for @conf.xc@: @"/var/mero/confd/conf.xc"@.
confXCPath :: FilePath
confXCPath = "/var/mero/confd/conf.xc"

-- | Create configuration for service and run mkfs if requested.
configureProcess :: MeroConf        -- ^ Mero configuration.
                 -> ProcessRunType  -- ^ Run type of the process.
                 -> ProcessConfig   -- ^ Process configuration.
                 -> Bool            -- ^ Is mkfs needed?
                 -> IO (Either (M0.Process, String) M0.Process)
configureProcess mc run conf needsMkfs = do
  let procFid = M0.fid p
  putStrLn $ "m0d: configureProcess: " ++ show procFid
           ++ " with type(s) " ++ show run
  confXC <- maybeWriteConfXC conf
  _unit  <- writeSysconfig mc run procFid (M0.r_endpoint p) confXC
  if needsMkfs
  then do
    ec <- SystemD.startService $ "mero-mkfs@" ++ fidToStr procFid
    return $ case ec of
      Right _ -> Right p
      Left x -> Left (p, "Unit failed to start with exit code " ++ show x)
  else return $ Right p
  where
    maybeWriteConfXC (ProcessConfigLocal _ bs) = do
      liftIO $ writeConfXC bs
      return $ Just confXCPath
    maybeWriteConfXC _ = return Nothing
    p = case conf of
      ProcessConfigLocal p' _ -> p'
      ProcessConfigRemote p' -> p'

-- | Start mero process.
--
-- We use 'SystemD.restartService' instead of 'SystemD.startService':
-- it's not harmful (except perhaps slightly confusing to anyone
-- reading logs) and prevents the scenario where for some reason the
-- service is still/already up and 'SystemD.startService' does nothing
-- meaningful.
startProcess :: ProcessRunType -- ^ Run type of the process.
             -> M0.Process     -- ^ Process itself.
             -> IO (Either (M0.Process, String) (M0.Process, Maybe Int))
startProcess run p = flip Catch.catch (generalProcFailureHandler p) $ do
  putStrLn $ "m0d: startProcess: " ++ fidToStr (M0.fid p) ++ " with type(s) " ++ show run
  SystemD.restartService (unitString run p) >>= return . \case
    Right mpid -> Right (p, mpid)
    Left x -> Left (p, "Unit failed to restart with exit code " ++ show x)

-- | Stop mero process.
--
-- The @systemctl@ stop command is given 60 seconds to run after which
-- point we assume and report failure for action.
stopProcess :: ProcessRunType        -- ^ Type of the process.
            -> M0.Process            -- ^ 'M0.Process' to stop.
            -> IO (Either (M0.Process, String) M0.Process)
stopProcess run p = flip Catch.catch (generalProcFailureHandler p) $ do
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
    ptimeoutSec = 60
    ptimeout = ptimeoutSec * 1000000

-- | Convert a process run type and 'Fid' to the corresponding systemd
-- service string.
unitString :: ProcessRunType       -- ^ Type of the process.
           -> M0.Process           -- ^ Process.
           -> String
unitString run p = case run of
  M0T1FS -> "m0t1fs@" ++ fidToStr (M0.fid p) ++ ".service"
  M0D -> "m0d@" ++ fidToStr (M0.fid p)  ++ ".service"

-- | General failure handler for the process start/stop/restart actions.
generalProcFailureHandler :: a -> Catch.SomeException
                          -> IO (Either (a, String) b)
generalProcFailureHandler obj e = return $ Left (obj, show e)

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

newtype Started = Started (SendPort NotificationMessage,SendPort ProcessControlMsg)
  deriving (Eq, Show, Binary)

m0dProcess :: ProcessId -> MeroConf -> Process ()
m0dProcess parent conf = do
  traceM0d "starting."
  Catch.bracket startKernel (\_ -> stopKernel) $ \rc -> do
    traceM0d "Kernel module loaded."
    case rc of
      Right _ -> flip Catch.catch epHandler . withEp $ \ep -> do
        self <- getSelfPid
        traceM0d "DEBUG: Pre-withEp"
        _ <- spawnLocal $ keepaliveProcess (mcKeepaliveFrequency conf)
                                           (mcKeepaliveTimeout conf) ep self
        c <- spawnChannelLocal (statusProcess ep self)
        traceM0d "DEBUG: Pre-withEp"
        cc <- spawnChannelLocal (controlProcess conf self)
        usend parent (Started (c,cc))
        sendMeroChannel c cc
        traceM0d "Starting service m0d on mero client"
        go c cc
      Left i -> do
        traceM0d $ "Kernel module did not load correctly: " ++ show i
        void . promulgate . M0.MeroKernelFailed parent $
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
      void . promulgate . M0.MeroKernelFailed parent $ msg

    -- Kernel
    startKernel = liftIO $ do
      _ <- SystemD.sysctlFile "mero-kernel"
        [ ("MERO_NODE_UUID", UUID.toString $ mkcNodeUUID (mcKernelConfig conf))
        ]
      SystemD.startService "mero-kernel"
    stopKernel =
       receiveTimeout 2000000 [] `Catch.finally` liftIO (void $ SystemD.stopService "mero-kernel")

    -- mainloop
    go c cc = forever $
      receiveWait
        [ match $ \ServiceStateRequest -> sendMeroChannel c cc
        ]

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
      void . promulgate $ CheckCleanup self
      cleanup <- expectTimeout (10 * 1000000)
      case cleanup of
        Just True -> (liftIO $ SystemD.startService "mero-cleanup")
          >>= \case
            Right _ -> return ()
            Left i -> do
              traceM0d $ "mero-cleanup did not run correctly: " ++ show i
              promulgateWait . M0.MeroCleanupFailed self $
                "mero-cleanup service failed to start: " ++ show i
              Control.Distributed.Process.die Shutdown
        Nothing ->
          -- This case is pretty unusual. Means some kind of major failure of
          -- the RC. Regardless, we continue, since at worst we just fail on
          -- the next step instead.
          traceM0d "Could not ascertain whether to run mero-cleanup."
        _ -> return ()
      pid <- spawnLocalName "service::m0d::process" $ do
        link self
        m0dProcess self conf
      monitor pid
      receiveWait
        [ matchIf (\(ProcessMonitorNotification _ p _) -> pid == p)
                $ \_ -> do
          void . promulgate . M0.MeroKernelFailed self $ "process exited."
          return (Left "failure during start")
        , match $ \(Started (c,cc)) -> do
          return (Right (pid,c,cc))
        ]
    mainloop _ s@(pid,c,cc) = do
      self <- getSelfPid
      return [ matchIf (\(ProcessMonitorNotification _ p _) -> pid == p)
                   $ \_ -> do
                 void . promulgate . M0.MeroKernelFailed self $ "process exited."
                 return (Failure, s)
             , match $ \ServiceStateRequest -> do
                 sendMeroChannel c cc
                 return (Continue, s)
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
-- * @halonctl@
m0d_real :: Service MeroConf
m0d_real = m0d
