--
-- Copyright (C) 2013 Xyratex Technology Limited. All rights reserved.
--

{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Tests (main) where

import Control.Distributed.Process.Scheduler (withScheduler, __remoteTable)
import Control.Distributed.Process.Node
import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Distributed.Process.Trans
import Control.Exception ( bracket, SomeException, throwIO )
import qualified Control.Exception as E ( catch )
import Control.Monad ( when, forM_, replicateM_, forM )
import Control.Monad ( replicateM )
import Control.Monad.State ( execStateT, modify, StateT, lift )
import Data.Function (on)
import Data.IORef
import Data.List ( nub, elemIndex, sortBy )
import qualified Network.Transport.TCP as TCP
import qualified Network.Transport as NT
import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)
import System.IO.Unsafe ( unsafePerformIO )


main :: IO ()
main = run 0

run :: Int -> IO ()
run s = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  bracket
    (TCP.createTransport "127.0.0.1" "8090" TCP.defaultTCPParameters)
    (either (const $ return ()) NT.closeTransport)
    $ \(Right transport) -> do
      res <- fmap nub $ forM [1..100] $ \i ->
        if schedulerIsEnabled
        then do
          -- running three times with the same seed should produce the same execution
          [res] <- fmap nub $ replicateM 3 $ execute transport (s+i)
          [res'] <- fmap nub $ replicateM 3 $ executeT transport (s+i)
          [res''] <- fmap nub $ replicateM 3 $ executeChan transport (s+i)
          [res'''] <- fmap nub $ replicateM 3 $ executeNSend transport (s+i)
          -- lifting Process has the same effect as running process unlifted
          True <- return $ res == res'
          checkInvariants res
          checkInvariants res''
          checkInvariants res'''
          return $ res ++ res'' ++ res'''
        else do
          res <- execute transport (s+i)
          checkInvariants res
          res' <- executeT transport (s+i)
          checkInvariants res'
          res'' <- executeChan transport (s+i)
          checkInvariants res''
          res''' <- executeNSend transport (s+i)
          checkInvariants res'''
          return $ res ++ res' ++ res'' ++ res'''
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

execute :: NT.Transport -> Int -> IO [String]
execute transport seed = do
      writeIORef traceR []
      n <- newLocalNode transport $ __remoteTable initRemoteTable
      flip E.catch (\e -> do putStr "execute.seed: " >> print seed
                             readIORef (traceR :: IORef [String]) >>= print
                             throwIO (e :: SomeException)
                 ) $
       runProcess' n $ withScheduler [] seed $ do
        self <- getSelfPid
        s0 <- spawnLocal $ do
          forM_ [0..1::Int] $ \i -> do
            j <- expect
            say' $ "s0: received " ++ show (j :: Int)
            send self (0::Int,i)
          send self ()
        s1 <- spawnLocal $ do
          forM_ [0..1::Int] $ \i -> do
            j <- expect
            say' $ "s1: received " ++ show (j :: Int)
            send self (1::Int,i)
          send self ()
        forM_ [0..1::Int] $ \i -> do
          send s0 (2*i)
          send s1 (2*i+1)
        replicateM_ 2 $ do
          i <- expect :: Process (Int,Int)
          say' $ "main: received " ++ show i
          j <- expect :: Process (Int,Int)
          say' $ "main: received " ++ show j
        () <- expect
        () <- expect
        liftIO $ fmap reverse $ readIORef traceR
 where
  {-# NOINLINE traceR #-}
  traceR = unsafePerformIO $ newIORef []
  say' = liftIO . modifyIORef traceR . (:)

executeNSend :: NT.Transport -> Int -> IO [String]
executeNSend transport seed = do
      writeIORef traceR []
      n0' <- newLocalNode transport $ __remoteTable initRemoteTable
      n1' <- newLocalNode transport $ __remoteTable initRemoteTable
      let [n0, n1] = sortBy (compare `on` localNodeId) [n0', n1']
      flip E.catch (\e -> do putStr "executeNSend.seed: " >> print seed
                             readIORef (traceR :: IORef [String]) >>= print
                             throwIO (e :: SomeException)
                 ) $ do
       runProcess' n0 $ withScheduler [] seed $ do
        self <- getSelfPid
        n <- getSelfNode
        register "self" self
        liftIO $ runProcess' n1 $ do
          s0 <- spawnLocal $ do
            forM_ [0..1::Int] $ \i -> do
              j <- expect
              say' $ "s0: received " ++ show (j :: Int)
              nsendRemote n "self" (0::Int,i)
            send self ()
          register "s0" s0
          s1 <- spawnLocal $ do
            forM_ [0..1::Int] $ \i -> do
              j <- expect
              say' $ "s1: received " ++ show (j :: Int)
              nsendRemote n "self" (1::Int,i)
            send self ()
          register "s1" s1

        forM_ [0..1::Int] $ \i -> do
          nsendRemote (localNodeId n1) "s0" (2*i)
          nsendRemote (localNodeId n1) "s1" (2*i+1)
        replicateM_ 2 $ do
          i <- expect :: Process (Int,Int)
          say' $ "main: received " ++ show i
          j <- expect :: Process (Int,Int)
          say' $ "main: received " ++ show j
        () <- expect
        () <- expect
        liftIO $ fmap reverse $ readIORef traceR
 where
  {-# NOINLINE traceR #-}
  traceR = unsafePerformIO $ newIORef []
  say' = liftIO . modifyIORef traceR . (:)


executeChan :: NT.Transport -> Int -> IO [String]
executeChan transport seed = do
      writeIORef traceR []
      n <- newLocalNode transport $ __remoteTable initRemoteTable
      flip E.catch (\e -> do putStr "executeChan.seed: " >> print seed
                             readIORef (traceR :: IORef [String]) >>= print
                             throwIO (e :: SomeException)
                 ) $
       runProcess' n $ withScheduler [] seed $ do
        self <- getSelfPid
        (spBack, rpBack) <- newChan
        _ <- spawnLocal $ do
          (sp, rp) <- newChan
          send self sp
          forM_ [0..1::Int] $ \i -> do
            j <- receiveChan rp
            say' $ "s0: received " ++ show (j :: Int)
            sendChan spBack (0::Int,i)
          send self ()
        sp0 <- expect
        _ <- spawnLocal $ do
          (sp, rp) <- newChan
          send self sp
          forM_ [0..1::Int] $ \i -> do
            j <- receiveChan rp
            say' $ "s1: received " ++ show (j :: Int)
            sendChan spBack (1::Int,i)
          send self ()
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
        liftIO $ fmap reverse $ readIORef traceR
 where
  {-# NOINLINE traceR #-}
  traceR = unsafePerformIO $ newIORef []
  say' = liftIO . modifyIORef traceR . (:)

instance MonadProcess Process where
  liftProcess = id

instance MonadProcess m => MonadProcess (StateT s m) where
  liftProcess = lift . liftProcess

executeT :: NT.Transport -> Int -> IO [String]
executeT transport seed = do
      writeIORef traceR []
      n <- newLocalNode transport $ __remoteTable initRemoteTable
      flip E.catch (\e -> do putStr "executeT.seed: " >> print seed
                             readIORef (traceR :: IORef [String]) >>= print
                             throwIO (e :: SomeException)
                 ) $
       runProcess' n $ withScheduler [] seed $ do
        self <- getSelfPid
        s0 <- spawnLocal $ killOnError self $ do
          2 <- flip execStateT 0 $ do
            forM_ [0..1::Int] $ \i -> do
              j <- receiveWaitT [ matchT $ \j -> modify (+j) >> return j ]
              liftProcess $ do say' $ "s0: received " ++ show (j :: Int)
                               send self (0::Int,i)
          send self ()
        s1 <- spawnLocal $ killOnError self $ do
          4 <- flip execStateT 0 $ do
            forM_ [0..1::Int] $ \i -> do
              j <- receiveWaitT [ matchT $ \j -> modify (+j) >> return j ]
              liftProcess $ do say' $ "s1: received " ++ show (j :: Int)
                               send self (1::Int,i)
          send self ()
        forM_ [0..1::Int] $ \i -> do
          send s0 (2*i)
          send s1 (2*i+1)
        replicateM_ 2 $ do
          i <- expect :: Process (Int,Int)
          say' $ "main: received " ++ show i
          j <- expect :: Process (Int,Int)
          say' $ "main: received " ++ show j
        () <- expect
        () <- expect
        liftIO $ fmap reverse $ readIORef traceR
 where
  {-# NOINLINE traceR #-}
  traceR = unsafePerformIO $ newIORef []
  say' :: String -> Process ()
  say' = liftIO . modifyIORef traceR . (:)

  killOnError pid p = catch p $ \e -> liftIO (print e) >>
    exit pid (show (e :: SomeException)) >> liftIO (throwIO e)

-- | Like 'runProcess' but forwards exceptions and returns the result of the
-- 'Process' computation.
runProcess' :: LocalNode -> Process a -> IO a
runProcess' n p = do
  r <- newIORef undefined
  runProcess n (try (getSelfNode >>= linkNode >> p) >>= liftIO . writeIORef r)
    >> readIORef r
      >>= either (\e -> throwIO (e :: SomeException)) return
