--
-- This modules defines functions to probe if a remote
-- host is alive.
--
{-# Language LambdaCase        #-}
{-# Language PatternGuards     #-}
{-# Language OverloadedStrings #-}
module Control.Distributed.Commands.Internal.Probes
    ( tryTimes
    , waitPing
    , waitSSH
    ) where

import Control.Concurrent (threadDelay)
import Control.Distributed.Commands.Internal.Log (debugLog)
import Control.Exception (throwIO, bracketOnError)
import Data.Time.Clock.POSIX
import Network (connectTo, withSocketsDo, PortID(..))
import System.IO (hClose, hGetLine, hClose, openFile, IOMode(..))
import System.IO.Error (ioeGetErrorType, tryIOError, doesNotExistErrorType)
import System.Process
    ( terminateProcess
    , CreateProcess(..)
    , proc
    , StdStream(..)
    , createProcess
    )
import System.Timeout

-- | Waits until the given host replies to pings.
waitPing :: String -> IO ()
waitPing host = do
    debugLog $ "Starting ping to " ++ host
    bracketOnError (openFile "/dev/null" ReadWriteMode) hClose $ \dev_null -> do
      (_, Just sout, ~(Just _), ph) <- createProcess (proc "ping" [ host ])
        { std_out = CreatePipe
        , std_err = UseHandle dev_null
        }
      -- We assume that the host has responded when ping prints two lines.
      _ <- hGetLine sout
      _ <- hGetLine sout
      terminateProcess ph

-- | Waits until the given host accepts TCP connections on the ssh port
-- the SSH port.
-- This function replaces a previous hardcoded timeout of 10 seconds
-- with repeated probes up to 30 seconds.
waitSSH :: String -> IO ()
waitSSH host = withSocketsDo $ do 
  debugLog $ "Starting SSH poll to " ++ host
  tryTimes "SSH poll" 30 500000 $ do
    r <- tryIOError $ connectTo host (Service "ssh")
    case r of
      -- A successful TCP connection
      Right socket -> hClose socket >> return True

      -- An error that is usually TCP connection refused, so we
      -- indicate a retry
      Left ioe | ioeGetErrorType ioe == doesNotExistErrorType -> do
        debugLog ("Caught doesNotExist IOError - this generally means the SSH server is not up yet.")
        return False

      -- some other error, that we rethrow
      Left ioe -> ioError ioe

  return ()

tryTimes :: String -> Integer -> Int -> IO Bool -> IO ()
tryTimes descr 0 _ _ = throwIO $ userError $ "Tried " ++ descr ++ " too many times"
tryTimes descr n delay action = do
  debugLog $ "Trying " ++ descr ++ ", " ++ (show n) ++ " iterations left"
  startTime <- getPOSIXTime
  res <- timeout delay action
  case res of

    -- we timed out. so retry immediatly
    Nothing -> tryTimes descr (n-1) delay action

    -- action succeeded
    Just True -> return () -- we succeeded

    -- action failed. we will have used some of the delay time already
    -- so we need to delay by what remains
    Just False -> do
       endTime <- getPOSIXTime
       let timeTaken = endTime - startTime
           timeTakenUs = floor $ timeTaken / 1000000
           remainingDelay = delay - timeTakenUs
       threadDelay remainingDelay
       tryTimes descr (n-1) delay action

