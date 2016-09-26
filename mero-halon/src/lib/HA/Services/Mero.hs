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
    , m0dProcess__sdict
    , m0dProcess__tdict
    , m0d__static
    , Mero.Notification.getM0Worker
    ) where

import HA.Logger
import HA.EventQueue.Producer (promulgate, promulgateWait)
import qualified HA.RecoveryCoordinator.Events.Mero as M0
import HA.Service
import HA.Services.Mero.Types

import qualified Mero.Notification
import Mero.Notification (NIRef)
import Mero.ConfC (Fid, fidToStr)

import qualified Network.RPC.RPCLite as RPC

import Control.Monad (unless)
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
  m0d = Service "m0d"
          $(mkStaticClosure 'm0dProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictMeroConf))

  m0dProcess :: MeroConf -> Process ()
  m0dProcess conf = do
    traceM0d "starting."
    Catch.bracket startKernel (\_ -> stopKernel) $ \rc -> do
      traceM0d "Kernel module loaded."
      case rc of
        ExitSuccess -> withEp $ \ep -> do
          self <- getSelfPid
          traceM0d "DEBUG: Pre-withEp"
          _ <- spawnLocal $ keepaliveProcess (mcKeepaliveFrequency conf)
                                             (mcKeepaliveTimeout conf) ep self
          c <- spawnChannelLocal (statusProcess ep self)
          traceM0d "DEBUG: Pre-withEp"
          cc <- spawnChannelLocal (controlProcess conf self)
          sendMeroChannel c cc
          traceM0d "Starting service m0d on mero client"
          go c cc
        ExitFailure i -> do
          self <- getSelfPid
          traceM0d $ "Kernel module did not load correctly: " ++ show i
          void . promulgate . M0.MeroKernelFailed self $
            "mero-kernel service failed to start: " ++ show i
          Control.Distributed.Process.die Shutdown
    where
      profileFid = mcProfile conf
      processFid = mcProcess conf
      rmFid      = mcRM      conf
      haFid      = mcHA      conf
      haAddr = RPC.rpcAddress $ mcHAAddress conf
      withEp = Mero.Notification.withNI haAddr processFid profileFid haFid rmFid

      -- Kernel
      startKernel = liftIO $ do
        SystemD.sysctlFile "mero-kernel"
          [ ("MERO_NODE_UUID", UUID.toString $ mkcNodeUUID (mcKernelConfig conf))
          ]
        SystemD.startService "mero-kernel"
      -- XXX: halon uses mero kernel module so it's not possible to
      -- unload that.
      stopKernel = return () -- liftIO $ SystemD.stopService "mero-kernel"

      -- mainloop
      go c cc = forever $
        receiveWait
          [ match $ \ServiceStateRequest -> do
             sendMeroChannel c cc
          ]
    |] ]
