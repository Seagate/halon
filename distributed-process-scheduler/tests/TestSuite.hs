--
-- Copyright (C) 2013 Seagate Technology LLC and/or its Affiliates. Apache License, Version 2.0.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module TestSuite (main) where

import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler (withScheduler)
import qualified Control.Distributed.Process.Scheduler as S (__remoteTable)
import Control.Distributed.Process.Node
import Control.Distributed.Process
import Control.Distributed.Process.Scheduler
  ( schedulerIsEnabled
  , addFailures
  , removeFailures
  )
import Control.Distributed.Process.Internal.Primitives
import Control.Distributed.Process.Internal.Types (ProcessExitException(..))
import Control.Distributed.Process.Trans
import Control.Monad ( when, forM_, replicateM_, forM )
import Control.Monad ( replicateM )
import Control.Monad.Catch as C
import Control.Monad.State ( execStateT, modify, StateT, lift )
import Data.Int
import Data.IORef
import Data.List ( nub, elemIndex )
import qualified Network.Transport.InMemory as InMemory
import qualified Network.Transport as NT
import System.Clock
import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)
import System.IO.Unsafe ( unsafePerformIO )


-- | microseconds/transition
clockSpeed :: Int
clockSpeed = 2000

say' :: String -> Process ()
say' = liftIO . modifyIORef traceR . (:)

{-# NOINLINE traceR #-}
traceR :: IORef [String]
traceR = unsafePerformIO $ newIORef []

resetTraceR :: IO ()
resetTraceR = writeIORef traceR []

killOnError :: ProcessId -> Process a -> Process a
killOnError pid p = C.catch p $ \e -> liftIO (print e) >>
    exit pid (show (e :: SomeException)) >> throwM e

senderProcess0 :: ProcessId -> Process ()
senderProcess0 self = do
    forM_ [0..1::Int] $ \i -> do
      j <- expect
      say' $ "s0: received " ++ show (j :: Int)
      usend self (0::Int,i)
    usend self ()

senderProcessT0 :: ProcessId -> Process ()
senderProcessT0 self = killOnError self $ do
    2 <- flip execStateT 0 $ do
      forM_ [0..1::Int] $ \i -> do
        j <- receiveWaitT [ matchT $ \j -> modify (+j) >> return j ]
        liftProcess $ do say' $ "s0: received " ++ show (j :: Int)
                         usend self (0::Int,i)
    usend self ()

remotable [ 'senderProcess0, 'senderProcessT0 ]

remoteTable :: RemoteTable
remoteTable =  -- eliminate warning about unused binding
    flip const [senderProcess0__tdict, senderProcessT0__tdict] $
      __remoteTable $ S.__remoteTable initRemoteTable

main :: IO ()
main = run 0

run :: Int -> IO ()
run s = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    res <- fmap nub $ forM [1..100] $ \i ->
      C.bracket InMemory.createTransport
                NT.closeTransport
      $ \transport -> do
        if schedulerIsEnabled
        then do
          -- running three times with the same seed should produce the same execution
          [res0] <- fmap nub $ replicateM 3 $
            execute "receiveTest" (const receiveTest) 1 transport (s+i)
          checkInvariants res0
          [res1] <- fmap nub $ replicateM 3 $
            execute "processTTest" (const processTTest) 1 transport (s+i)
          -- lifting Process has the same effect as running process unlifted
          True <- return $ res0 == res1
          [res2] <- fmap nub $ replicateM 3 $
            execute "chanTest" (const chanTest) 1 transport (s+i)
          checkInvariants res2
          -- Warning: Node identifiers reach 10 in the following test.
          --
          -- Having a tests use node ids with different amounts of digits will
          -- cause confusion due to a current limitation in the scheduler.
          -- See limitation in the README file.
          [res3] <- fmap nub $ replicateM 3 $
            execute "nsendTest" nsendTest 2 transport (s+i)
          checkInvariants res3
          [res4] <- fmap nub $ replicateM 3 $
            execute "registerTest" (const registerTest) 1 transport (s+i)
          [res5] <- fmap nub $ replicateM 3 $
            execute "timeoutsTest" (const timeoutsTest) 1 transport (s+i)
          [res6] <- fmap nub $ replicateM 3 $
            execute "dropMessagesTest" dropMessagesTest 3 transport (s+i)
          [res7] <- fmap nub $ replicateM 3 $
            execute "uforwardTest" (const uforwardTest) 1 transport (s+i)
          [res8] <- fmap nub $ replicateM 3 $
            execute "remoteChanTest" remoteChanTest 2 transport (s+i)
          checkInvariants res8
          res9 <- execute "sayTest" sayTest 2 transport (s+i)
          res10 <- execute "linkTest" (const linkTest) 2 transport (s+i)
          when (i `mod` 10 == 0) $
            putStrLn $ show i ++ " iterations"
          return $ res0 ++ res2 ++ res3 ++ res4 ++ res5 ++ res6 ++ res7 ++
                   res8 ++ res9 ++ res10
        else do
          res0 <- execute "receiveTest" (const receiveTest) 1 transport (s+i)
          checkInvariants res0
          res1 <- execute "processTTest" (const processTTest) 1 transport (s+i)
          checkInvariants res1
          res2 <- execute "chanTest" (const chanTest) 1 transport (s+i)
          checkInvariants res2
          res3 <- execute "nsendTest" nsendTest 2 transport (s+i)
          checkInvariants res3
          res4 <- execute "registerTest" (const registerTest) 1 transport (s+i)
          res5 <- execute "timeoutsTest" (const timeoutsTest) 1 transport (s+i)
          res6 <- execute "uforwardTest"  (const uforwardTest) 1 transport (s+i)
          res7 <- execute "sayTest" sayTest 2 transport (s+i)
          res8 <- execute "linkTest" (const linkTest) 2 transport (s+i)
          when (i `mod` 10 == 0) $
            putStrLn $ show i ++ " iterations"
          return $ res0 ++ res1 ++ res2 ++ res3 ++ res4 ++ res5 ++ res6 ++
                   res7 ++ res8
    putStrLn $ "Test passed with " ++ show (length res) ++ " different traces."
 where
   checkInvariants res = do
       -- every execution in the provided example should have exactly 8 transitions
       when (8 /= length res) (error $ "Test Failed: " ++ show res)
       -- messages to each process should be delivered in order
       when (not $ check res) (error $ "Test Failed: " ++ show res)
   check res = indexOf "s0: received 0" res < indexOf "s0: received 2" res
            && indexOf "s1: received 1" res < indexOf "s1: received 3" res
            && indexOf "main: received (0,0)" res < indexOf "main: received (0,1)" res
            && indexOf "main: received (1,0)" res < indexOf "main: received (1,1)" res
   indexOf a = maybe (error "indexOf: no such element") id . elemIndex a

-- | Intercepts 'say' messages from processes as a crude way to know that an
-- action following an asynchronous send has completed.
registerInterceptor ::
    (String -> Process ())
    -- ^ Intercepter hook. Takes 'String' message sent with 'say'
    -> Process ()
registerInterceptor hook = do
    Just logger <- whereis "logger"

    let loop = receiveWait
            [ match $ \msg@(SayMessage _ _ string) -> do
                  hook string
                  usend logger msg
                  loop
            , matchAny $ \amsg -> do
                  uforward amsg logger
                  loop ]

    reregister "logger" =<< spawnLocal loop

execute :: String
        -> ([LocalNode] -> Process ())
        -> Int
        -> NT.Transport
        -> Int
        -> IO [String]
execute label test numNodes transport seed = do
   resetTraceR
   flip C.catch (\e -> do putStr (label ++ ".seed: ") >> print seed
                          readIORef (traceR :: IORef [String]) >>= print
                          throwM (e :: SomeException)
                 ) $ do
     withScheduler seed clockSpeed numNodes transport remoteTable test
     fmap reverse $ readIORef traceR

sayTest :: [LocalNode] -> Process ()
sayTest = \(n1 : _) -> do
    self <- getSelfPid
    _ <- liftIO $ forkProcess n1 $ do
      registerInterceptor $ \s -> do
        liftIO $ putStrLn $ "intercepted string " ++ show s
        usend self s
      usend self ()
    () <- expect
    liftIO $ putStrLn "registered interceptor"
    _ <- liftIO $ forkProcess n1 $ do
      say "hello"
    "hello" <- expect
    return ()

linkTest :: Process ()
linkTest = do
    pid <- spawnLocal (expect :: Process ())
    link pid
    _ :: Either ProcessLinkException () <- C.try $ do
      exit pid "linkTest finished"
      unlink pid
    -- We test here that ProcessLinkException does not arrive after unlink
    -- completes.
    _ <- receiveTimeout 1000 []
    return ()

receiveTest :: Process ()
receiveTest = do
    self <- getSelfPid
    here <- getSelfNode
    s0 <- spawn here $ $(mkClosure 'senderProcess0) self
    s1 <- spawnLocal $ do
      forM_ [0..1::Int] $ \i -> do
        j <- expect
        say' $ "s1: received " ++ show (j :: Int)
        usend self (1::Int,i)
      usend self ()
    forM_ [0..1::Int] $ \i -> do
      usend s0 (2*i)
      usend s1 (2*i+1)
    replicateM_ 2 $ do
      i <- expect :: Process (Int,Int)
      say' $ "main: received " ++ show i
      j <- expect :: Process (Int,Int)
      say' $ "main: received " ++ show j
    () <- expect
    expect

registerTest :: Process ()
registerTest = do
    self <- getSelfPid
    here <- getSelfNode
    -- s1 links to s0
    -- self monitors s1
    -- self terminates s0
    -- then s1 should terminate
    -- then self should terminate
    s0 <- spawnLocal $ do
      () <- expect
      say' "s0: blocking"
      Left (ProcessExitException pid msg) <-
        C.try $ do usend self ()
                   receiveWait [] :: Process ()
      True <- return $ self == pid
      Just True <- handleMessage msg (return . ("terminate" ==))
      say' "s0: terminated"
    s1 <- spawnLocal $ do
      link s0
      say' "s1: blocking"
      Left (ProcessLinkException pid DiedNormal) <-
        C.try $ do usend s0 ()
                   receiveWait [] :: Process ()
      True <- return $ s0 == pid
      say' "s1: terminated"
    whereisRemoteAsync here "s0"
    WhereIsReply "s0" Nothing <- expect
    say' "main: registering s0"
    registerRemoteAsync here "s0" s0
    RegisterReply "s0" True _ <- expect
    say' "main: registered s0"
    registerRemoteAsync here "s0" s0
    RegisterReply "s0" False _ <- expect
    say' "main: cannot reregister s0"
    whereisRemoteAsync here "s0"
    WhereIsReply "s0" (Just s0') <- expect
    True <- return $ s0' == s0
    say' "main: terminating s0"
    () <- expect
    ref <- monitor s1
    do ref0 <- monitor s1
       -- Test that unmonitoring ref0 does not invalidate ref.
       unmonitor ref0
    exit s0 "terminate"
    ProcessMonitorNotification ref' s1' DiedNormal <- expect
    True <- return $ ref == ref'
    True <- return $ s1 == s1'
    return ()

uforwardTest :: Process ()
uforwardTest = do
    mainPid <- getSelfPid
    s0 <- spawnLocal $ do
      usend mainPid ()
      say' "s0: blocking"
      () <- expect
      say' "s0: terminated"
      usend mainPid ()
    say' "main: blocking"
    receiveWait [ matchAny (flip uforward s0) ]
    say' "main: terminated"
    expect

timeoutsTest :: Process ()
timeoutsTest = do
    mainPid <- getSelfPid
    s0 <- spawnLocal $ do
      () <- expect
      say' "s0: terminating"
      usend mainPid ()
    say' "main: receiveTimeout"
    t0 <- liftIO $ getTime Monotonic
    Nothing <- receiveTimeout 3000 [ match $ \() -> return () ]
    t1 <- liftIO $ getTime Monotonic
    True <- return $ timeSpecToMicro (t1 - t0) >= 3000
    say' "main: expectTimeout"
    Nothing <- expectTimeout 3000 :: Process (Maybe ())
    t2 <- liftIO $ getTime Monotonic
    True <- return $ timeSpecToMicro (t2 - t1) >= 3000
    usend s0 ()
    say' "main: terminated"
    expect
  where
    timeSpecToMicro :: TimeSpec -> Int64
    timeSpecToMicro (TimeSpec s ns) = s * 1000000 + ns `div` 1000

dropMessagesTest :: [LocalNode] -> Process ()
dropMessagesTest = \(n1 : n2 : _) -> do
    mainPid <- getSelfPid
    s1 <- liftIO $ forkProcess n1 $ do
      s2 <- expect

      () <- expect
      say' "s1: sending 1"
      ref <- monitor s2
      usend s2 ()
      ProcessMonitorNotification ref' s2' DiedDisconnect <- expect
      True <- return $ ref == ref'
      True <- return $ s2 == s2'

      () <- expect
      say' "s1: sending 2"
      usend s2 ()
      Nothing <- expectTimeout 1000000
        :: Process (Maybe ProcessMonitorNotification)

      () <- expect
      say' "s1: sending 3"
      usend s2 ()
      Nothing <- expectTimeout 1000000
        :: Process (Maybe ProcessMonitorNotification)
      say' "s1: terminating"
      usend mainPid ()

    s2 <- liftIO $ forkProcess n2 $ do
      () <- expect
      say' "s2: sending 1"
      usend mainPid ()

      () <- expect
      say' "s2: sending 2"
      usend mainPid ()

      say' "s2: terminating"
      usend mainPid ()

    usend s1 s2
    _ <- monitor s1

    -- No message should be sent to main
    addFailures [((localNodeId n1, localNodeId n2), 1.0)]
    usend s1 ()
    Nothing <- expectTimeout 1000000 :: Process (Maybe ())
    Nothing <- expectTimeout 1000000
      :: Process (Maybe ProcessMonitorNotification)
    say' "main: timeout"

    -- A message should be sent to main
    removeFailures [(localNodeId n1, localNodeId n2)]
    usend s1 ()
    () <- expect
    say' "main: received 1"

    -- A message should be sent to main
    addFailures [((localNodeId n2, localNodeId n1), 1.0)]
    usend s1 ()
    () <- expect
    say' "main: received 2"
    () <- expect
    expect

nsendTest :: [LocalNode] -> Process ()
nsendTest = \(n1 : _) -> do
    self <- getSelfPid
    n <- getSelfNode
    register "self" self
    _ <- liftIO $ forkProcess n1 $ do
      s0 <- spawnLocal $ do
        forM_ [0..1::Int] $ \i -> do
          j <- expect
          say' $ "s0: received " ++ show (j :: Int)
          nsendRemote n "self" (0::Int,i)
        usend self ()
      register "s0" s0
      s1 <- spawnLocal $ do
        forM_ [0..1::Int] $ \i -> do
          j <- expect
          say' $ "s1: received " ++ show (j :: Int)
          nsendRemote n "self" (1::Int,i)
        usend self ()
      register "s1" s1
      usend self ((), ())
    ((), ()) <- expect

    forM_ [0..1::Int] $ \i -> do
      nsendRemote (localNodeId n1) "s0" (2*i)
      nsendRemote (localNodeId n1) "s1" (2*i+1)
    replicateM_ 2 $ do
      i <- expect :: Process (Int,Int)
      say' $ "main: received " ++ show i
      j <- expect :: Process (Int,Int)
      say' $ "main: received " ++ show j
    () <- expect
    expect

chanTest :: Process ()
chanTest = do
    self <- getSelfPid
    (spBack, rpBack) <- newChan
    _ <- spawnLocal $ do
      (sp, rp) <- newChan
      usend self sp
      forM_ [0..1::Int] $ \i -> do
        j <- receiveChan rp
        say' $ "s0: received " ++ show (j :: Int)
        sendChan spBack (0::Int,i)
      usend self ()
    sp0 <- expect
    _ <- spawnLocal $ do
      (sp, rp) <- newChan
      usend self sp
      forM_ [0..1::Int] $ \i -> do
        j <- receiveChan rp
        say' $ "s1: received " ++ show (j :: Int)
        sendChan spBack (1::Int,i)
      usend self ()
    sp1 <- expect
    forM_ [0..1::Int] $ \i -> do
      sendChan sp0 (2*i)
      sendChan sp1 (2*i+1)
    replicateM_ 2 $ do
      i <- receiveChan rpBack
      say' $ "main: received " ++ show i
      j <- receiveChan rpBack
      say' $ "main: received " ++ show j
    () <- expect
    expect

remoteChanTest :: [LocalNode] -> Process ()
remoteChanTest = \(n1 : _) -> do
  localPid <- getSelfPid
  (>> expect) $ liftIO $ forkProcess n1 $ do
    self <- getSelfPid
    (spBack, rpBack) <- newChan
    _ <- spawnLocal $ do
      (sp, rp) <- newChan
      usend self sp
      forM_ [0..1::Int] $ \i -> do
        j <- receiveChan rp
        say' $ "s0: received " ++ show (j :: Int)
        sendChan spBack (0::Int,i)
      usend self ()
    sp0 <- expect
    _ <- spawnLocal $ do
      (sp, rp) <- newChan
      usend self sp
      forM_ [0..1::Int] $ \i -> do
        j <- receiveChan rp
        say' $ "s1: received " ++ show (j :: Int)
        sendChan spBack (1::Int,i)
      usend self ()
    sp1 <- expect
    forM_ [0..1::Int] $ \i -> do
      sendChan sp0 (2*i)
      sendChan sp1 (2*i+1)
    replicateM_ 2 $ do
      i <- receiveChan rpBack
      say' $ "main: received " ++ show i
      j <- receiveChan rpBack
      say' $ "main: received " ++ show j
    () <- expect
    () <- expect
    usend localPid ()

instance MonadProcess Process where
  liftProcess = id

instance MonadProcess m => MonadProcess (StateT s m) where
  liftProcess = lift . liftProcess

processTTest :: Process ()
processTTest = do
    self <- getSelfPid
    here <- getSelfNode
    s0 <- spawn here $ $(mkClosure 'senderProcessT0) self
    s1 <- spawnLocal $ killOnError self $ do
      4 <- flip execStateT 0 $ do
        forM_ [0..1::Int] $ \i -> do
          j <- receiveWaitT [ matchT $ \j -> modify (+j) >> return j ]
          liftProcess $ do say' $ "s1: received " ++ show (j :: Int)
                           usend self (1::Int,i)
      usend self ()
    forM_ [0..1::Int] $ \i -> do
      usend s0 (2*i)
      usend s1 (2*i+1)
    replicateM_ 2 $ do
      i <- expect :: Process (Int,Int)
      say' $ "main: received " ++ show i
      j <- expect :: Process (Int,Int)
      say' $ "main: received " ++ show j
    () <- expect
    expect
