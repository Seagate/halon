{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE PackageImports  #-}
{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns    #-}
-- |
-- Module    : HA.Services.Mero.Mock
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
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
import           Data.Tuple (swap)
import qualified Data.UUID as UUID (toString, UUID)
import qualified Data.UUID.V4 as UUID (nextRandom)
import qualified Debug.Trace as D
import           GHC.Generics (Generic)
import           HA.Debug
import           HA.EventQueue.Producer
import qualified HA.RecoveryCoordinator.Mero.Events as M0
import qualified HA.Resources.Mero as M0
import           HA.Service
import           HA.Services.Mero ( confXCPath, sendMeroChannel
                                  , Started(..), unitString )
import           HA.Services.Mero.RC.Events
import           HA.Services.Mero.Types
import           Mero.ConfC (Fid(..), fidToStr, ServiceType(..))
import           Mero.Notification.HAState
import qualified "distributed-process-scheduler" System.Clock as C
import           System.IO.Unsafe (unsafePerformIO)
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
  { _m_last_pid :: Int
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
sendProcessEvents :: M0.Process -- ^ Process to send events about
                  -> ProcessEventType -- ^ What is happening to the process?
                  -> ServiceEventType -- ^ What is happening to the services?
                  -> Int -- ^ Process ID
                  -> Process ()
sendProcessEvents p petype setype pid = do
  liftIO $ D.traceEventIO "START sendProcessEvents"
  pmap <- liftIO $ _m_process_map <$> readIORef mockLocalState
  case Map.lookup p pmap of
    Nothing -> sendProcessEvent TAG_M0_CONF_HA_PROCESS_M0D
    Just (_ps_svcs -> srvs) -> do
      for_ srvs $ \s -> sendServiceEvent s
      sendProcessEvent (guessProcessType srvs)
  liftIO $ D.traceEventIO "STOP sendProcessEvents"
  where
    guessProcessType :: [M0.Service] -> ProcessType
    guessProcessType [] = TAG_M0_CONF_HA_PROCESS_M0D
    guessProcessType srvs | any isM0T1FS srvs = TAG_M0_CONF_HA_PROCESS_KERNEL
                          | otherwise = TAG_M0_CONF_HA_PROCESS_M0D
      where
        isM0T1FS :: M0.Service -> Bool
        isM0T1FS (M0.s_type -> t) = t `notElem` [CST_IOS, CST_MDS, CST_MGS, CST_HA]

    sendProcessEvent :: ProcessType -> Process ()
    sendProcessEvent pt = do
      t <- liftIO $ C.sec <$> C.getTime C.Realtime
      let ev = ProcessEvent { _chp_event = petype
                            , _chp_type  = pt
                            , _chp_pid = fromIntegral pid }
          meta = HAMsgMeta { _hm_fid = M0.fid p
                           , _hm_source_process = Fid 0 0
                           , _hm_source_service = Fid 0 0
                           , _hm_time = fromIntegral t }
      promulgateWait $ HAMsg ev meta

    sendServiceEvent :: M0.Service -> Process ()
    sendServiceEvent s = do
      t <- liftIO $ C.sec <$> C.getTime C.Realtime
      let ev = ServiceEvent { _chs_event = setype
                            , _chs_type = M0.s_type s }
          meta = HAMsgMeta { _hm_fid = M0.fid s
                           , _hm_source_process = Fid 0 0
                           , _hm_source_service = Fid 0 0
                           , _hm_time = fromIntegral t }
      promulgateWait $ HAMsg ev meta

-- | Mock-exclusive global state.
mockLocalState :: IORef MockLocalState
{-# NOINLINE mockLocalState #-}
mockLocalState = unsafePerformIO $ newIORef defaultMockLocalState

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
          sayMock $ printf "systemctl %s %s.service; fake PID => %d" cmd svcN pid
        Nothing -> do
          sayMock $ printf "systemctl %s %s.service" cmd svcN
      return $! Right pid
    Just rc -> do
      sayMock $ printf "systemctl %s %s.service, failing with %d" cmd svcN rc
      return $! Left rc
  where
    retrievePID :: IO Int
    retrievePID = atomicModifyIORef' mockLocalState $ \mls ->
      case mp >>= \p' -> Map.lookup p' (_m_process_map mls) >>= _ps_pid of
        Nothing -> swap $ mls & m_last_pid <+~ 1
        Just pid -> (mls, pid)

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
      ps -> promulgateWait . KeepaliveTimedOut
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
      p | p `S.member` fps -> promulgateWait $ NotificationFailure epoch p
        | otherwise -> promulgateWait $ NotificationAck epoch p
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
    ConfigureProcess runType pconf mkfs ->
      configureProcess runType pconf mkfs >>=
        promulgateWait . ProcessControlResultConfigureMsg nid
    StartProcess runType p -> startProcess runType p >>=
      promulgateWait . ProcessControlResultMsg nid
    StopProcess runType p -> stopProcess runType p >>=
      promulgateWait . ProcessControlResultStopMsg nid
  where
    writeSysconfig runType pfid m0addr confdPath = do
      let prefix = case runType of { M0T1FS -> "m0t1fs" ; M0D -> "m0d" }
          fileName = prefix ++ "-" ++ fidToStr pfid
      _ <- mockRunSysconfig fileName $
        [ ("MERO_" ++ fmap toUpper prefix ++ "_EP", m0addr)
        , ("MERO_HA_EP", mcHAAddress conf)
        , ("MERO_PROFILE_FID", fidToStr $ mcProfile conf)
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
      writeSysconfig runType (M0.fid p) (M0.r_endpoint p) confxc
      if needsMkfs
      then mockRunCmd "start" ("mero-mkfs@" ++ fidToStr (M0.fid p)) Nothing <&> \case
        Right{} -> Right p
        Left rc -> Left (p, "Unit failed to start with exit code " ++ show rc)
      else return $! Right p

    startProcess :: ProcessRunType -> M0.Process
                 -> Process (Either (M0.Process, String) (M0.Process, Maybe Int))
    startProcess runType p = do
      -- Get old PID if any: after we mock restart, we should send
      -- STOPPED messages first with old PID before sending new ones.
      mop <- liftIO (readIORef mockLocalState) <&> \mls ->
        Map.lookup p (_m_process_map mls) >>= _ps_pid

      mockRunCmd "restart" (unitString runType p) (Just p) >>= \case
        Right pid -> do
          for_ mop $ \oldPid ->
            sendProcessEvents p TAG_M0_CONF_HA_PROCESS_STOPPED
                                TAG_M0_CONF_HA_SERVICE_STOPPED
                                oldPid

          -- Update process with new PID
          liftIO . atomicModifyIORef' mockLocalState $ \mls ->
            let f (Just ops) = Just $ ops { _ps_pid = Just pid }
                f _          = Nothing
            in (mls & m_process_map %~ Map.alter f p, ())
          sendProcessEvents p TAG_M0_CONF_HA_PROCESS_STARTED
                              TAG_M0_CONF_HA_SERVICE_STARTED
                              pid
          return $! Right (p, Just pid)
        Left rc ->
          return $! Left (p, "Unit falied to restart with exit code " ++ show rc)

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
  mockWaiter $ \_ -> [ match $ \(caller, u, MockInitialiseFinished) -> do
                         usend caller $! MockCmdAck u
                         sayMock "Initialise finished." ]
  sayMock "Starting main process."
  Catch.bracket startKernel (\_ -> stopKernel) $ \rc -> do
    sayMock "Kernel module ’loaded’."
    case rc of
      Right (haProc, haPid) -> do
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
        usend parent $ Started (c, cc)
        sendMeroChannel c cc
        sayMock "Starting service m0d:mock on mero client."
        mockWaiter $ \waitForMore ->
          [ match $ \ServiceStateRequest -> sendMeroChannel c cc >> waitForMore ]
      Left i -> do
        sayMock $ "Kernel module did not load correctly: " ++ show i
        promulgateWait . M0.MeroKernelFailed parent $
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
  m0dMock = Service "m0d:mock"
              $(mkStaticClosure 'm0dFunctions)
              ($(mkStatic 'someConfigDict)
                  `staticApply` $(mkStatic 'configDictMeroConf))

  m0dFunctions :: ServiceFunctions MeroConf
  m0dFunctions = ServiceFunctions bootstrap mainloop teardown confirm where
    bootstrap conf = do
      self <- getSelfPid
      promulgateWait $ CheckCleanup self
      expectTimeout (10 * 1000000) >>= \case
        Just True -> mockRunCmd "start" "mero-cleanup" Nothing >>= \case
          Right _ -> return ()
          Left i -> do
            sayMock $ "mero-cleanup did not run correctly: " ++ show i
            promulgateWait . M0.MeroCleanupFailed self $ do
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
            promulgateWait . M0.MeroKernelFailed self $ "process exited."
            return (Left "failure during start")
        , match $ \(Started (c, cc)) -> return $! Right (m0dPid, c, cc)
        ]
    mainloop _ s@(pid,c,cc) = do
      self <- getSelfPid
      return [ matchIf (\(ProcessMonitorNotification _ p _) -> pid == p)
                   $ \_ -> do
                 promulgateWait $ M0.MeroKernelFailed self "process exited."
                 return (Failure, s)
             , match $ \ServiceStateRequest -> do
                 sendMeroChannel c cc
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