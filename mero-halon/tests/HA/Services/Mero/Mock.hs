{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE PackageImports  #-}
{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns    #-}
{-# LANGUAGE MonoLocalBinds  #-}

-- |
-- Module    : HA.Services.Mero.Mock
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- A mock @halon:m0d@ service used for testing without actually
-- running mero components.
--
-- TODO/to discuss: It's not inconceivable that instead of this module
-- trying to match functionality of the real deal, the service in
-- "HA.Services.Mero" itself could be changed such that it has ’gaps’
-- for workers. In that case we would simply have something like
--
-- @
-- data MeroServiceSetup = MeroServiceSetup
--   { _mss_configureProcess :: 'MeroConf' -> 'ProcessRunType' -> …
--   …
--   }
--
-- -- HA.Services.Mero
-- realM0dSetup = MeroServiceSetup 'HA.Services.Mero.configureProcess' …
--
-- HA.Services.Mero.Mock
-- mockM0dSetup = MeroServiceSetup ('HA.Services.Mero.Mock.mockRunCmd' …) …
--
-- mkM0d :: MeroServiceSetup -> Service MeroConf
--
-- m0d = mkM0d realM0dSetup
-- mockM0d = mkM0d mockM0dSetup
-- @
--
-- With this we would be forced to implement mocks that behave
-- similarly enough to real deal and would not miss any messages,
-- while getting the layout ‘for free’.
module HA.Services.Mero.Mock
  ( FailCmd(..)
  , KeepaliveTimedOutCmd(..)
  , MockCmdAck(..)
  , MockInitialiseFinished(..)
  , SetNotNotifiable(..)
  , SetProcessMap(..)
  , HA.Services.Mero.Mock.__remoteTableDecl
  , m0dMock
  , m0dMockWorkerLabel
  , sendMockCmd
  , clearMockState
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Serializable
import           Control.Distributed.Static
import           Control.Exception (SomeException)
import           Control.Lens hiding (set)
import           Control.Monad (forever)
import qualified Control.Monad.Catch as Catch
import           Data.Binary (Binary)
import           Data.Char (toUpper)
import           Data.Foldable (for_)
import           Data.Function (fix)
import           Data.IORef
import qualified Data.Map as Map
import           Data.Monoid ((<>))
import qualified Data.Set as S
import qualified Data.Text as T
import           Data.Tuple (swap)
import qualified Data.UUID as UUID (toString, UUID)
import qualified Data.UUID.V4 as UUID (nextRandom)
import qualified Debug.Trace as D
import           GHC.Generics (Generic)
import           HA.Debug
import           HA.EventQueue.Producer
import qualified HA.Resources.Mero as M0
import           HA.Service
import           HA.Service.Interface
import           HA.Services.Mero (confXCPath, InternalStarted(..), unitString)
import           HA.Services.Mero.Types
import           Mero.ConfC (Fid(..), m0_fid0, ServiceType(..))
import           Mero.Lnet (encodeEndpoint)
import           Mero.Notification.HAState
  ( HAMsg(..)
  , HAMsgMeta(..)
  , ProcessEvent(..)
  , ProcessEventType(..)
  , ProcessType(..)
  , ServiceEvent(..)
  , ServiceEventType(..)
  , m0_time_now
  )
import qualified "distributed-process-scheduler" System.Clock as C
import           System.IO.Unsafe (unsafePerformIO)
import qualified System.Posix.Process as Posix
import           Text.Printf (printf)

-- | Meta-info about a 'M0.Process'.
data ProcessState = ProcessState
  { _ps_pid :: Maybe Int
  , _ps_svcs :: [M0.Service]
  } deriving (Show, Eq)

-- | State that belongs to the mock instance of halon:m0d only. Used
-- to compensate for lack of external inputs.
--
-- TODO: Move this into a 'NodeId'-indexed map: this way
-- separate mock instances won't source from each-other's data and we
-- can catch bugs that interact with wrong halon:m0d instance.
data MockLocalState = MockLocalState
  { _m_last_pid :: !Int
  -- ^ Last PID we assigned in 'mockRunSvc'.
  , _m_cmd_failures :: Map.Map (String, String) [Int]
  -- ^ A 'Map.Map' of @(command, service) -> [exitcodes]@. It informs
  -- 'mockRunCmd' whether the next invoctation of 'mockRunCmd command
  -- service' should fail and if yes, with what exit code.
  , _m_keepalive_failures :: S.Set M0.Process
  -- ^ A set of processes that should fail due to keepalive the next
  -- time 'keepaliveProcess' runs.
  , _m_not_notifiable :: S.Set Fid
  -- ^ A set of processes that 'statusProcess' should report
  -- 'NotificationFaliure' for in response to 'NotificationMessage'.
  , _m_process_map :: Map.Map M0.Process ProcessState
  -- ^ Store what services belong to what process to allow for sending
  -- of 'ProcessEvent's and 'ServiceEvent's when process start is
  -- requested. Necessary as we don't actually start anything and mero
  -- can never send this.
  } deriving (Show, Eq)
makeLenses ''MockLocalState

-- | Initial state for 'MockLocalState'.
defaultMockLocalState :: MockLocalState
defaultMockLocalState = MockLocalState
  { _m_last_pid = 1000
  , _m_cmd_failures = Map.empty
  , _m_keepalive_failures = S.empty
  , _m_not_notifiable = S.empty
  , _m_process_map = Map.empty
  }

-- | Helper for users: sends any message to the @halon:m0d:service@,
-- attaching UUID and own 'ProcessId'. When the service processes the
-- message, it sends back 'MockCmdAck' provided here. User can then
-- wait for this ack.
--
-- These mock commands bypass the interface.
sendMockCmd :: (Show a, Eq a, Serializable a)
                 => a -- ^ Message
                 -> ProcessId -- ^ @halon:m0d:mock@ service 'ProcessId'
                 -> Process MockCmdAck
sendMockCmd msg mockPid = do
  self <- getSelfPid
  uuid <- liftIO UUID.nextRandom
  usend mockPid (self, uuid, msg)
  return $! MockCmdAck uuid

-- | Fail the next @'mockRunCmd' cmd svcN@ with the given exit code.
-- In case of multiple invocations of 'FailCmd' for the same
-- command, the most recently provided exit code will be produced
-- for first invocation (LIFO).
data FailCmd = FailCmd String String Int
  deriving (Show, Eq, Ord, Generic)
instance Binary FailCmd

-- | Next time keepalive runs, act as if the given process has failed
-- to reply on time.
newtype KeepaliveTimedOutCmd = KeepaliveTimedOutCmd M0.Process
  deriving (Show, Eq, Ord, Generic)
instance Binary KeepaliveTimedOutCmd

-- | Next time a notification comes, the recepients specified here
-- will report 'NotificationFailed'.
newtype SetNotNotifiable = SetNotNotifiable [M0.Process]
  deriving (Show, Eq, Ord, Generic)
instance Binary SetNotNotifiable

-- | Next time a notification comes, the recepients specified here
-- will report 'NotificationFailed'.
newtype SetProcessMap = SetProcessMap [(M0.Process, [M0.Service])]
  deriving (Show, Eq, Ord, Generic)
instance Binary SetProcessMap

-- | Tell the mock that we're done populating state and to start its
-- normal course of action.
data MockInitialiseFinished = MockInitialiseFinished
  deriving (Show, Eq, Ord, Generic)
instance Binary MockInitialiseFinished

newtype MockCmdAck = MockCmdAck UUID.UUID
  deriving (Show, Eq, Ord, Generic, Binary)

-- | 'say' with easily-identified header.
sayMock :: String -> Process ()
sayMock m = do
  nid <- getSelfNode
  say $ "[halon:m0d:mock:" ++ show nid ++ "]: " ++ m

-- | Send 'ServiceEvent's and 'ProcessEvent's about process/service
-- start; it's usually mero's work to do this and we rely on these
-- messages.
sendProcessEvents :: M0.Process       -- ^ Process to send events about.
                  -> ProcessEventType -- ^ What is happening to the process?
                  -> ServiceEventType -- ^ What is happening to the services?
                  -> Int              -- ^ Process ID.
                  -> Process ()
sendProcessEvents p petype setype pid = do
  liftIO $ D.traceEventIO "START sendProcessEvents"
  pmap <- liftIO $ _m_process_map <$> readIORef mockLocalState
  case Map.lookup p pmap of
    Nothing -> sendProcessEvent pid TAG_M0_CONF_HA_PROCESS_M0D
    Just (_ps_svcs -> svcs) -> do
      let pt = guessProcessType svcs
          pid' = if (pt == TAG_M0_CONF_HA_PROCESS_KERNEL) then 0
                                                          else pid
      for_ svcs $ \s -> sendServiceEvent pid' s
      D.traceM $ "sendProcessEvents: svcs=" ++ show svcs ++
                 " type=" ++ show pt
      sendProcessEvent pid' pt
  liftIO $ D.traceEventIO "STOP sendProcessEvents"
  where
    guessProcessType :: [M0.Service] -> ProcessType
    guessProcessType [] = TAG_M0_CONF_HA_PROCESS_M0D
    guessProcessType svcs | any isNotClientSvc svcs = TAG_M0_CONF_HA_PROCESS_M0D
                          | otherwise = TAG_M0_CONF_HA_PROCESS_KERNEL
      where
        isNotClientSvc :: M0.Service -> Bool
        isNotClientSvc (M0.s_type -> t) = t `elem` [CST_IOS, CST_MDS, CST_CONFD,
                                                    CST_CAS, CST_ADDB2, CST_HA]

    sendProcessEvent :: Int -> ProcessType -> Process ()
    sendProcessEvent pid' pt = do
      t <- liftIO $ C.sec <$> C.getTime C.Realtime
      let ev = ProcessEvent { _chp_event = petype
                            , _chp_type = pt
                            , _chp_pid = fromIntegral pid' }
          meta = HAMsgMeta { _hm_fid = M0.fid p
                           , _hm_source_process = m0_fid0
                           , _hm_source_service = m0_fid0
                           , _hm_time = fromIntegral t
                           , _hm_epoch = 0 }
      promulgateWait $ HAMsg ev meta

    sendServiceEvent :: Int -> M0.Service -> Process ()
    sendServiceEvent pid' s = do
      t <- liftIO $ C.sec <$> C.getTime C.Realtime
      let ev = ServiceEvent { _chs_event = setype
                            , _chs_type = M0.s_type s
                            , _chs_pid = fromIntegral pid' }
          meta = HAMsgMeta { _hm_fid = M0.fid s
                           , _hm_source_process = m0_fid0
                           , _hm_source_service = m0_fid0
                           , _hm_time = fromIntegral t
                           , _hm_epoch = 0 }
      promulgateWait $ HAMsg ev meta

-- | Mock-exclusive global state.
mockLocalState :: IORef MockLocalState
{-# NOINLINE mockLocalState #-}
mockLocalState = unsafePerformIO $ newIORef defaultMockLocalState

-- | Set 'mockLocalState' to 'defaultMockLocalState'. This is useful
-- for cases where we run multiple tests in a single executable
-- invocation: the state doesn't get cleared automatically because the
-- program doesn't restart.
--
-- Note that it's up to the caller to invoke this because only the
-- caller knows when new test starts: the service can't decide when it
-- should drop state as it has no information about any other mock
-- services using it.
clearMockState :: IO ()
clearMockState = writeIORef mockLocalState defaultMockLocalState

-- | Pretend to run a systemctl command and return the PID of the
-- started process. Succeeds unless previously requested to
-- fail through 'FailCmd'.
--
-- If a 'M0.Process' is passed in and command is ‘successful’, the PID
-- of that process is returned. Otherwise a new PID is returned.
mockRunCmd :: String -- ^ Command, e.g. "start"
           -> String -- ^ Service, e.g. "mero-cleanup"
           -> Maybe M0.Process -- ^ Is the command associated with a
                               -- particular process?
           -> Process (Either Int Int)
mockRunCmd cmd svcN mp = do
  mrc <- liftIO . atomicModifyIORef' mockLocalState $ \mls ->
    let m = _m_cmd_failures mls
    in case Map.lookup (cmd, svcN) m of
      Nothing -> (mls, Nothing)
      Just [] -> (mls & m_cmd_failures %~ Map.delete (cmd, svcN), Nothing)
      Just (x:xs) -> (mls & m_cmd_failures %~ Map.insert (cmd, svcN) xs, Just x)
  case mrc of
    Nothing -> liftIO retrievePID >>= \pid -> do
      case mp of
        Just{} ->
          sayMock $ printf "systemctl %s %s; fake PID => %d" cmd svcN pid
        Nothing -> do
          sayMock $ printf "systemctl %s %s" cmd svcN
      return $! Right pid
    Just rc -> do
      sayMock $ printf "systemctl %s %s, failing with %d" cmd svcN rc
      return $! Left rc
  where
    retrievePID :: IO Int
    retrievePID = atomicModifyIORef' mockLocalState $ \mls ->
      case mp >>= \p' -> Map.lookup p' (_m_process_map mls) of
        -- We already have some PID for this process, just return it.
        Just (ProcessState { _ps_pid = Just pid }) -> (mls, pid)
        -- We don't have a PID but before assigning one, check if it's
        -- m0t1fs. If yes, PID 0.
        Just (ProcessState { _ps_svcs = svcs })
          | all (\s -> M0.s_type s `notElem`
                  [CST_IOS, CST_MDS, CST_CONFD, CST_HA]) svcs -> (mls, 0)
        -- We don't have a PID for this process (or have process
        -- without state), just assign next available PID.
        _ -> swap $ mls & m_last_pid <+~ 1

-- | Report what sysconfig info was requested to be written and where.
-- Does not actually write any data. Always succeeds ('Nothing').
mockRunSysconfig :: FilePath -> [(String, String)] -> Process (Maybe SomeException)
mockRunSysconfig fp vars = do
  sayMock $ printf "Requested new sysconfig ‘%s’ with values %s" fp (show vars)
  return Nothing

-- | Mock of a keepalive process. Instead of doing any real keepalive
-- to non-existing processes, it checks '_m_keepalive_failures' and
-- sends information about 'M0.Process'es contained there. To populate
-- '_m_keepalive_failures' use
-- @'sendMockCmd' ('KeepaliveTimedOutCmd' p) …@.
keepaliveProcess :: Int -- ^ Frequency (seconds)
                 -> Int -- ^ Timeout (seconds)
                 -> ProcessId -- ^ Master
                 -> Process ()
keepaliveProcess kaFreq kaTimeout master = do
  link master
  forever $ do
    _ <- receiveTimeout (kaFreq * 1000000) []
    fs <- liftIO . atomicModifyIORef' mockLocalState $ \mls ->
      ( mls & m_keepalive_failures .~ S.empty
      , mls ^. m_keepalive_failures )
    case S.toList fs of
      [] -> return ()
      ps -> sendRC interface . KeepaliveTimedOut
        $ map (\p -> (M0.fid p, M0.mkTimeSpec $ fromIntegral kaTimeout)) ps

-- | Mock process handling 'NotificationMessage's comming in on a
-- channel. Unlike a real process, we can't rely on callbacks from
-- 'notifyMero' code. Instead, for @'NotificationMessage' _ _ ps@ we
-- send 'NotificationFaliure' for every @ps@ that's in
-- '_m_not_notifiable' and 'NotificationAck' for every @ps@ that
-- isn't. The reason is that unexpected notification acks do not hurt
-- but unexpected notification failures (for 'M0.PSOnline' processes)
-- can.
statusProcess :: ProcessId -- ^ Master
              -> ReceivePort NotificationMessage -- ^ Notification channel
              -> Process ()
statusProcess master nmChan = do
  link master
  forever $ do
    msg@(NotificationMessage epoch _ ps) <- receiveChan nmChan
    liftIO $ D.traceEventIO "START statusProcess"
    sayMock $ "statusProcess: Received " ++ show msg
    fps <- liftIO $ _m_not_notifiable <$> readIORef mockLocalState
    for_ ps $ \case
      p | p `S.member` fps -> sendRC interface $ NotificationFailure epoch p
        | otherwise -> sendRC interface $ NotificationAck epoch p
    liftIO $ D.traceEventIO "STOP statusProcess"

-- | A mock process for 'ProcessControlMsg' handler.
--
-- Unlike the real process, it does not perform commands in
-- asynchronous manner.
--
-- TODO: We could extend this to be async and extend 'mockRunCmd' to
-- possibly run long and block. This would allow us to emulate any
-- scenarios where multiple different process control messages are
-- sent for a single process.
controlProcess :: MeroConf -- ^ Service conf
               -> ProcessId -- ^ Master
               -> ReceivePort ProcessControlMsg -- ^ Control message channel
               -> Process ()
controlProcess conf master pcChan = do
  link master
  nid <- getSelfNode
  forever $ receiveChan pcChan >>= \case
    ConfigureProcess runType pconf _env mkfs uid ->
      configureProcess runType pconf mkfs >>=
        sendRC interface . ProcessControlResultConfigureMsg uid
    StartProcess runType p -> startProcess runType p >>=
      sendRC interface . ProcessControlResultMsg
    StopProcess runType p -> stopProcess runType p >>=
      sendRC interface . ProcessControlResultStopMsg nid
  where
    writeSysconfig runType pfid m0addr confdPath = do
      let prefix = case runType of { M0T1FS -> "m0t1fs"
                                   ; M0D -> "m0d"
                                   ; CLOVIS s -> s
                                   }
          fileName = prefix ++ "-" ++ show pfid
      _ <- mockRunSysconfig fileName $
        [ ("MERO_" ++ fmap toUpper prefix ++ "_EP", m0addr)
        , ("MERO_HA_EP", mcHAAddress conf)
        , ("MERO_PROFILE_FID", show (mcProfile conf))
        ] ++ maybe [] (\p -> [("MERO_CONF_XC", p)]) confdPath
      return ()

    configureProcess :: ProcessRunType -> ProcessConfig -> Bool
                     -> Process (Either (M0.Process, String) M0.Process)
    configureProcess runType pconf needsMkfs = do
      let confxc = case pconf of
            ProcessConfigLocal{} -> Just confXCPath
            _ -> Nothing
          p = case pconf of
            ProcessConfigLocal p' _ -> p'
            ProcessConfigRemote p' -> p'
      writeSysconfig runType (M0.fid p)
                     (T.unpack . encodeEndpoint $ M0.r_endpoint p)
                     confxc
      if needsMkfs
      then mockRunCmd "start" ("mero-mkfs@" ++ show (M0.fid p)) Nothing <&> \case
        Right{} -> Right p
        Left rc -> Left (p, "Unit failed to start with exit code " ++ show rc)
      else return $! Right p

    startProcess :: ProcessRunType -> M0.Process
                 -> Process ProcessControlStartResult
    startProcess runType p = do
      -- Get old PID if any: after we mock restart, we should send
      -- STOPPED messages first with old PID before sending new ones.
      mop <- liftIO (readIORef mockLocalState) <&> \mls ->
        Map.lookup p (_m_process_map mls) >>= _ps_pid

      case mop of
        Just{} -> return $! RequiresStop p
        Nothing -> mockRunCmd "start" (unitString runType p) (Just p) >>= \case
          Right pid -> do
            -- Update process with new PID
            liftIO . atomicModifyIORef' mockLocalState $ \mls ->
              let f (Just ops) = Just $ ops { _ps_pid = Just pid }
                  f _          = Nothing
              in (mls & m_process_map %~ Map.alter f p, ())
            sendProcessEvents p TAG_M0_CONF_HA_PROCESS_STARTED
                                TAG_M0_CONF_HA_SERVICE_STARTED
                                pid
            return $! Started p pid
          Left rc ->
            return . StartFailure p $ "Unit falied to restart with exit code " ++ show rc

    stopProcess :: ProcessRunType -> M0.Process
                -> Process (Either (M0.Process, String) M0.Process)
    stopProcess runType p = do
      mockRunCmd "stop" (unitString runType p) (Just p) >>= \case
        Right oldPid -> do
          -- Remove PID from now-stopped process
          liftIO . atomicModifyIORef' mockLocalState $ \mls ->
            let f (Just ops) = Just $ ops { _ps_pid = Nothing }
                f _          = Nothing
            in (mls & m_process_map %~ Map.alter f p, ())
          sendProcessEvents p TAG_M0_CONF_HA_PROCESS_STOPPED
                              TAG_M0_CONF_HA_SERVICE_STOPPED
                              oldPid
          return $! Right p
        Left rc -> return $! Left (p, "Unit failed to stop with exit code " ++ show rc)

-- | Handlers for mock-exclusive messages. Every mock command is
-- expected to be of form @('ProcessId', a)@ so that it may be
-- acknowledged. Use 'sendMockCmd' to assure this.
mockWaiter :: (Process () -> [Match ()])
           -- ^ Any extra matches on top of mock ones.
           -> Process ()
mockWaiter extraMatches = fix $ \loop -> receiveWait $
  [ match $ \(caller, u, FailCmd cmd svcN rc) -> do
      liftIO . atomicModifyIORef' mockLocalState $ \mls -> do
        (mls & m_cmd_failures %~ Map.insertWith (<>) (cmd, svcN) [rc], ())
      usend caller $! MockCmdAck u
      loop
  , match $ \(caller, u, KeepaliveTimedOutCmd p) -> do
      liftIO . atomicModifyIORef' mockLocalState $ \mls -> do
        (mls & m_keepalive_failures %~ S.insert p, ())
      usend caller $! MockCmdAck u
      loop
  , match $ \(caller, u, SetNotNotifiable ps) -> do
      liftIO . atomicModifyIORef' mockLocalState $ \mls -> do
        (mls & m_not_notifiable .~ S.fromList (map M0.fid ps), ())
      usend caller $! MockCmdAck u
      loop
  , match $ \(caller, u, SetProcessMap ps) -> do
      liftIO . atomicModifyIORef' mockLocalState $ \mls ->
        let ps' = map (\(p, srvs) -> (p, ProcessState Nothing srvs)) ps
        in (mls & m_process_map %~ (`Map.union` Map.fromList ps'), ())

      usend caller $! MockCmdAck u
      loop
  ] ++ extraMatches loop

-- | Label used  by 'm0dMockProcess'.
m0dMockWorkerLabel :: String
m0dMockWorkerLabel = "service::m0d::process"

-- | Main m0d mock process.
m0dMockProcess :: ProcessId -> MeroConf -> Process ()
m0dMockProcess parent conf = do
  sayMock "Welcome to halon:m0d mock, initialising…"

  -- If we have CST_HA for this service in state already, assume
  -- service restarted (or has been restarted on purpose) and don't go
  -- through second initialise.
  pmap <- liftIO $ Map.keys . _m_process_map <$> readIORef mockLocalState
  if mcProcess conf `elem` map M0.fid pmap
  then sayMock $ "Service seems to have been initialised already."
  else mockWaiter $ \_ ->
    [ match $ \(caller, u, MockInitialiseFinished) -> do
        usend caller $! MockCmdAck u
        sayMock "Initialise finished." ]
  sayMock "Starting main process."
  Catch.bracket startKernel (\_ -> stopKernel) $ \rc -> do
    sayMock "Kernel module ’loaded’."
    case rc of
      Right (haProc, haPid) -> do
        sayMock $ printf "HA: %s, PID => %s" (show $ M0.fid haProc) (show haPid)
        sendProcessEvents haProc TAG_M0_CONF_HA_PROCESS_STARTED
                                 TAG_M0_CONF_HA_SERVICE_STARTED
                                 haPid
        self <- getSelfPid
        sayMock $ "Spawning keepalive process"
        _ <- spawnLocal $ keepaliveProcess (mcKeepaliveFrequency conf)
                                           (mcKeepaliveTimeout conf)
                                           self
        sayMock $ "Spawning status process"
        c <- spawnChannelLocal $ statusProcess self
        sayMock $ "Spawning control process"
        cc <- spawnChannelLocal $ controlProcess conf self
        usend parent $ InternalStarted (c, cc)
        sayMock "Starting service m0d:mock on mero client."
        mockWaiter $ \_ -> []
      Left i -> do
        sayMock $ "Kernel module did not load correctly: " ++ show i
        sendRC interface . MeroKernelFailed (processNodeId parent) $
          "mero-kernel service failed to start: " ++ show i
        Control.Distributed.Process.die Shutdown
  where
    startKernel = do
      _ <- mockRunSysconfig "mero-kernel"
        [ ("MERO_NODE_UUID", UUID.toString $ mkcNodeUUID (mcKernelConfig conf)) ]
      pmap <- liftIO $ _m_process_map <$> readIORef mockLocalState
      case [ p | p <- Map.keys pmap, M0.fid p == mcProcess conf ] of
        [] -> do
          sayMock $ "CST_HA process missing from mock data."
          return $! Left (-42)
        p : _ -> mockRunCmd "start" "mero-kernel" (Just p) >>= \case
          Left rc -> return $! Left rc
          Right pid -> return $! Right (p, pid)
    stopKernel = do
      -- Should we send stopped process event for CST_HA process?
      mockRunCmd "stop" "mero-kernel" Nothing

remotableDecl [ [d|
  m0dMock :: Service MeroConf
  m0dMock = Service (ifServiceName interface)
              $(mkStaticClosure 'm0dFunctions)
              ($(mkStatic 'someConfigDict)
                  `staticApply` $(mkStatic 'configDictMeroConf))

  m0dFunctions :: ServiceFunctions MeroConf
  m0dFunctions = ServiceFunctions bootstrap mainloop teardown confirm where
    bootstrap conf = do
      self <- getSelfPid
      sendRC interface $ CheckCleanup (processNodeId self)
      cleanup <- receiveTimeout (10 * 1000000)
        [ receiveSvcIf interface
            (\case Cleanup{} -> True
                   _ -> False)
            (\case Cleanup b -> return b
                   -- ‘impossible’
                   _ -> return False) ]
      case cleanup of
        Just True -> mockRunCmd "start" "mero-cleanup" Nothing >>= \case
          Right _ -> return ()
          Left i -> do
            sayMock $ "mero-cleanup did not run correctly: " ++ show i
            sendRC interface . MeroCleanupFailed (processNodeId self) $ do
              "mero-cleanup service failed to start: " ++ show i
            Control.Distributed.Process.die Shutdown
        Nothing -> sayMock "Could not ascertain whether to run mero-cleanup."
        Just False -> sayMock "mero-cleanup not required."
      m0dPid <- spawnLocalName m0dMockWorkerLabel $ do
        link self
        getSelfPid >>= register m0dMockWorkerLabel
        m0dMockProcess self conf
      monitor m0dPid
      receiveWait
        [ matchIf (\(ProcessMonitorNotification _ p _) -> m0dPid == p)
              $ \_ -> do
            unregister m0dMockWorkerLabel
            sendRC interface . MeroKernelFailed (processNodeId self) $ "process exited."
            return (Left "failure during start")
        , match $ \(InternalStarted (c, cc)) -> return $! Right (m0dPid, c, cc)
        ]
    mainloop conf s@(pid,c,cc) = do
      nid <- getSelfNode
      return [ matchIf (\(ProcessMonitorNotification _ p _) -> pid == p)
                   $ \_ -> do
                 sendRC interface $ MeroKernelFailed nid "process exited."
                 return (Failure, s)
             , receiveSvc interface $ \case
                 PerformNotification nm -> do
                   sendChan c nm
                   return (Continue, s)
                 ProcessMsg pm -> do
                   sendChan cc pm
                   return (Continue, s)
                 AnnounceYourself -> do
                   sys_pid <- liftIO $ fromIntegral <$> Posix.getProcessID
                   t <- liftIO m0_time_now
                   let meta = HAMsgMeta { _hm_fid = mcProcess conf
                                        , _hm_source_process = mcProcess conf
                                        , _hm_source_service = mcHA conf
                                        , _hm_time = t
                                        , _hm_epoch = 0 }
                       evt = ProcessEvent { _chp_event = TAG_M0_CONF_HA_PROCESS_STARTED
                                          , _chp_type = TAG_M0_CONF_HA_PROCESS_M0D
                                          , _chp_pid = sys_pid }
                   sendRC interface . AnnounceEvent $ HAMsg evt meta
                   return (Continue, s)
             ]
    teardown _ (pid, _, _) = do
      mref <- monitor pid
      exit pid "teardown"
      receiveWait
        [ matchIf (\(ProcessMonitorNotification m _ _) -> mref == m)
                  (\_ -> return ()) ]
    confirm _ _ = return ()
  |] ]

-- | Silence unused values warning.
_unused :: ()
_unused = ()
  where
    _ = m0dMock__static
