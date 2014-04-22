-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Convenience functions to make "Test" from cabal package and "Process" work
-- together.
--
-- This module re-exports "Distribution.TestSuite" for convenience.
--

module Test.Framework
    ( module Distribution.TestSuite
    , testSuccess
    , testFailure
    , withTmpDirectory
    , Timeout(..)
    , defaultTimeout
    , tryWithTimeout
    , assert
    , registerInterceptor
    , terminateLocalProcesses
    ) where

import Distribution.TestSuite

import Control.Distributed.Process hiding ( bracket, try )
import Control.Distributed.Process.Internal.StrictMVar
    ( newEmptyMVar, modifyMVar, putMVar, takeMVar )
import Control.Distributed.Process.Internal.Types
    ( localProcesses, LocalNode, LocalNodeState, localState, processId )
import Control.Distributed.Process.Node ( newLocalNode, closeLocalNode, runProcess )

import Network.Transport (Transport)

import Control.Applicative ((<$>), (<*))
import Control.Concurrent ( forkIO, killThread, myThreadId, threadDelay, throwTo )
import Control.Exception ( AssertionFailed(..), Exception, SomeException
                         , bracket, throw, try )
import Control.Monad ( replicateM_, void )
import Data.Typeable (Typeable)
import System.Directory (getCurrentDirectory, setCurrentDirectory)
import System.Process (readProcess)


import Data.Accessor ((^.))
import qualified Data.Map as Map ( elems )

-- | Smart constructor for simple test.
--
-- Create a test with given name and action. When given action fails, the
-- test will be considered as 'Fail'.
--
testSuccess :: String -> IO () -> Test
testSuccess name t = Test $ TestInstance
    { run = try t >>= either (\(e :: SomeException) -> return $ Finished $ Fail $ show e)
                             (\_ -> return $ Finished $ Pass)
    , tags = []
    , options = []
    , setOption = \_ _ -> Left "No options supported."
    , .. }

-- | Smart constructor for simple test.
--
-- Create a test with given name and action. When given actions fails, the
-- test will be considered as 'Pass'.
--
testFailure :: String -> IO () -> Test
testFailure name t = Test $ TestInstance
    { run = try t >>= either (\(_ :: SomeException) -> return $ Finished $ Pass)
                             (\_ -> return $ Finished $ Fail $ "Unexpected test case success.")
    , tags = []
    , options = []
    , setOption = \_ _ -> Left "No options supported."
    , .. }

-- | Runs given test inside newly created temporary directory.
withTmpDirectory :: Test -> Test
withTmpDirectory (Test TestInstance{..}) =
    Test $ TestInstance{ run = do
        cwd <- getCurrentDirectory
        tmpdir <- init <$> readProcess "mktemp" ["-d"] ""
        setCurrentDirectory tmpdir
        run <* setCurrentDirectory cwd, .. }
withTmpDirectory (Group{..}) = Group{groupTests = map withTmpDirectory groupTests, ..}
withTmpDirectory (ExtraOptions opts t) = ExtraOptions opts (withTmpDirectory t)

-- | Exception indicating timeout has occured.
data Timeout = Timeout
             deriving (Show, Typeable)

instance Exception Timeout

-- | Default timeout, 5 seconds.
defaultTimeout :: Int
defaultTimeout = 5000000

-- | Run given 'Process' in a bracket throwing 'Timeout' exception.
tryWithTimeout ::
    Transport      -- ^ Transport for running given Process.
    -> RemoteTable -- ^ RemoteTable for running given Process.
    -> Int         -- ^ Timeout value in nanoseconds.
    -> Process ()  -- ^ Process to run.
    -> IO ()
tryWithTimeout transport rtable timeout p = do
    tid <- liftIO myThreadId
    bracket
      -- Resource aquire
      (forkIO $ threadDelay timeout >> throwTo tid Timeout)
      -- Resource release
      killThread
      $ const $ bracket
          -- Resource aquire
          (newLocalNode transport rtable)
          -- Resource release
          closeLocalNode
          -- Action
          $ flip runProcess $
                 catch p (\(e :: SomeException) -> liftIO $ throwTo tid e)

-- | Throws 'AssertionFailed' exception when given value is 'False'.
assert :: Bool -> Process ()
assert True  = say "Assertion success."
assert False = throw $ AssertionFailed "Assertion fail."

-- | Intercepts 'say' messages from processes as a crude way to know that an
-- action following an asynchronous send has completed.
registerInterceptor ::
    (String -> Process ())
    -- ^ Intercepter hook. Takes 'String' message sent with 'say'
    -> Process ()
registerInterceptor hook = do
    Just logger <- whereis "logger"

    let loop = receiveWait
            [ match $ \(msg@(_, _, string) :: (String, ProcessId, String)) -> do
                  hook string
                  send logger msg
                  loop
            , matchAny $ \amsg -> do
                  forward amsg logger
                  loop ]

    reregister "logger" =<< spawnLocal loop

-- | Terminates all processes running in the given node.
--
-- It takes an optional timeout in microseconds. If no timeout is given
-- it waits indefinitely until all processes die.
--
-- Returns True iff all processes were terminated.
--
terminateLocalProcesses :: LocalNode -> Maybe Int -> IO Bool
terminateLocalProcesses node mtimeout = do
    st <- modifyMVar (localState node) (\st -> return (st,st))
    mv <- newEmptyMVar
    runProcess node $ terminateProcesses st >>= liftIO . putMVar mv
    takeMVar mv
  where
    terminateProcesses :: LocalNodeState -> Process Bool
    terminateProcesses st = do
      let pids = map processId $ Map.elems (st ^. localProcesses)
      mapM_ monitor pids
      mapM_ (flip exit "closing node") pids
      case mtimeout of
        Just timeout -> do
          timer <- spawnLocal $ void $ receiveTimeout timeout []
          void $ monitor timer
          let loop 0 = do
                exit timer "all process were terminated"
                receiveWait
                  [ match $ \(ProcessMonitorNotification _ _ _) ->
                                return True
                  ]
              loop n = receiveWait
                [ match $ \(ProcessMonitorNotification _ mpid _) ->
                    if mpid == timer then return False
                      else loop (n-1)
                ]
          loop (length pids)
        Nothing -> do
          replicateM_ (length pids) $ receiveWait
            [ match $ \(ProcessMonitorNotification _ _ _) -> return () ]
          return True
