-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE LambdaCase            #-}
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
    , m0d
    , HA.Services.Mero.__remoteTableDecl
    , HA.Services.Mero.Types.__remoteTable
    , m0d__static
    , Mero.Notification.getM0Worker
    ) where

import HA.Debug
import HA.Logger
import HA.EventQueue.Producer (promulgate, promulgateWait)
import qualified HA.RecoveryCoordinator.Events.Mero as M0
import qualified HA.Resources.Mero as M0
import HA.Service
import HA.Services.Mero.Types

import qualified Mero.Notification
import Mero.Notification (NIRef)
import Mero.ConfC (Fid, fidToStr)

import qualified Network.RPC.RPCLite as RPC

import Control.Monad (unless)
import Control.Monad.Trans.Reader
import Control.Exception (SomeException, IOException)
import qualified Control.Distributed.Process.Internal.Types as DI
import Control.Distributed.Process.Closure
  ( remotableDecl
  , mkStatic
  , mkStaticClosure
  )
import Control.Distributed.Static
  ( staticApply )
import Control.Distributed.Process hiding (catch)
import Control.Monad.Catch (catch)
import Control.Monad (forever, void)
import qualified Control.Monad.Catch as Catch

import qualified Data.ByteString as BS
import Data.Char (toUpper)
import Data.Maybe (maybeToList)
import Data.Binary
import Data.Typeable
import GHC.Generics
import qualified Data.UUID as UUID

import System.Exit
import System.FilePath
import System.Directory
import qualified System.SystemD.API as SystemD
import qualified System.Timeout as ST

traceM0d :: String -> Process ()
traceM0d = mkHalonTracer "halon:m0d"


-- | Request information about service
data ServiceStateRequest = ServiceStateRequest
  deriving (Show, Typeable, Generic)

instance Binary ServiceStateRequest

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
--
-- TODO: usend: RC restarts then we want probably *do* want to lose
-- these messages as the job that caused them is going to restart and
-- receiving old results isn't fun.
--
-- TODO2: tag these with UUID so that we know that we're getting the
-- right reply to the right message, then it won't matter either way
controlProcess :: MeroConf
               -> ProcessId -- ^ Parent process to link to
               -> ReceivePort ProcessControlMsg
               -> Process ()
controlProcess mc pid rp = link pid >> (forever $ receiveChan rp >>= \case
    ConfigureProcess runType conf mkfs -> do
      nid <- getSelfNode
      result <- liftIO $ configureProcess mc runType conf mkfs
      promulgateWait $ ProcessControlResultConfigureMsg nid result
    StartProcess runType p -> do
      nid <- getSelfNode
      result <- liftIO $ startProcess runType p
      promulgateWait $ ProcessControlResultMsg nid result
    StopProcesses procs -> do
      nid <- getSelfNode
      results <- liftIO $ mapM (uncurry stopProcess) procs
      promulgateWait $ ProcessControlResultStopMsg nid results
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
startProcess :: ProcessRunType   -- ^ Type of the process.
             -> M0.Process              -- ^ Process Fid.
             -> IO (Either (M0.Process, String) (M0.Process, Maybe Int))
startProcess run p = flip Catch.catch (generalProcFailureHandler p) $ do
  putStrLn $ "m0d: startProcess: " ++ show (M0.fid p) ++ " with type(s) " ++ show run
  SystemD.restartService (unitString run (M0.fid p)) >>= return . \case
    Right mpid -> Right (p, mpid)
    Left x -> Left (p, "Unit failed to restart with exit code " ++ show x)

-- | Stop running mero service.
stopProcess :: ProcessRunType        -- ^ Type of the process.
            -> Fid                   -- ^ Process Fid.
            -> IO (Either (Fid, String) Fid)
stopProcess run fid = flip Catch.catch (generalProcFailureHandler fid) $ do
  let unit = unitString run fid
  putStrLn $ "m0d: stopProcess: " ++ unit ++ " with type(s) " ++ show run
  ec <- ST.timeout ptimeout $ SystemD.stopService unit
  case ec of
    Nothing -> do
      putStrLn $ unwords [ "m0d: stopProcess timed out after", show ptimeoutSec, "s for", show unit ]
      return $ Left (fid, "Failed to stop after " ++ show ptimeoutSec ++ "s")
    Just ExitSuccess -> do
      putStrLn $ "m0d: stopProcess OK for " ++ show unit
      return $ Right fid
    Just (ExitFailure x) -> do
      putStrLn $ "m0d: stopProcess failed."
      return $ Left (fid, "Unit failed to stop with exit code " ++ show x)
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

-- | General failure handler for the process start/stop/restart actions.
generalProcFailureHandler :: a -> Catch.SomeException
                          -> IO (Either (a, String) b)
generalProcFailureHandler obj e = return $ Left (obj, show e)

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
    stopKernel = liftIO $ SystemD.stopService "mero-kernel"

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
  m0dFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where
    bootstrap conf = do
      self <- getSelfPid
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
