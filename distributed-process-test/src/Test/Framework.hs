-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Convenience functions to make "Test" from cabal package and "Process" work
-- together.
--
-- This module re-exports "Distribution.TestSuite" for convenience.
--

module Test.Framework
  ( module Test.Tasty
  , testSuccess
  , testFailure
  , withTmpDirectory
  , Timeout(..)
  , defaultTimeout
  , tryWithTimeout
  , tryWithTimeoutIO
  , assert
  , assertMsg
  , registerInterceptor
  , terminateLocalProcesses
  , withLocalNode
  , withLocalNodes
  , getBuildPath
  ) where

import Control.Concurrent ( killThread )
import Control.Distributed.Process hiding
  ( bracket
  , finally
  , try
  )
import Control.Distributed.Process.Internal.Primitives (SayMessage(..))
import Control.Distributed.Process.Internal.StrictMVar
  ( modifyMVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Distributed.Process.Internal.Types
  ( LocalNode
  , LocalNodeState(..)
  , MxEventBus(..)
  , localEventBus
  , localProcessWithId
  , localProcesses
  , localState
  , processId
  , processLocalId
  , processThread
  )
import Control.Distributed.Process.Node
  ( closeLocalNode
  , newLocalNode
  , runProcess
  )
import Control.Exception
  ( AssertionFailed(..)
  , Exception
  , SomeException
  , finally
  , throw
  , throwIO
  , try
  )
import qualified Control.Exception as E
import Control.Monad
  ( replicateM_
  , void
  )
import Data.Accessor ((^.))
import Data.List
import qualified Data.Map as Map
import Data.Typeable (Typeable)
import Network.Transport (Transport)
import System.Directory
  ( getCurrentDirectory
  , removeDirectoryRecursive
  , setCurrentDirectory
  , getTemporaryDirectory
  )
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Temp (mkdtemp)
import System.Timeout
import Test.Tasty hiding (Timeout)
import Test.Tasty.HUnit hiding (assert)


-- | Smart constructor for simple test.
--
-- Create a test with given name and action. When given action fails, the
-- test will be considered as 'Fail'.
--
testSuccess :: String -> IO () -> TestTree
testSuccess = testCase

-- | Smart constructor for simple test.
--
-- Create a test with given name and action. When given actions fails, the
-- test will be considered as 'Pass'.
--
testFailure :: String -> IO () -> TestTree
testFailure name t = testCase name $
    try t >>= either (\(_ :: SomeException) -> return ())
                     (\_ -> assertFailure "Unexpected test case success.")

-- | Run the given action in a newly created temporary directory.
withTmpDirectory :: IO a -> IO a
withTmpDirectory action = do
    cwd <- getCurrentDirectory
    tmpRoot <- getTemporaryDirectory
    tmpDir <- mkdtemp $ tmpRoot </> "tmp."
    setCurrentDirectory tmpDir
    action `finally` do
      setCurrentDirectory cwd
      removeDirectoryRecursive tmpDir

-- | Exception indicating timeout has occured.
data Timeout = Timeout
             deriving (Show, Typeable)

instance Exception Timeout

-- | Default timeout, 5 seconds.
defaultTimeout :: Int
defaultTimeout = 5000000

-- | Runs the given 'Process' and throws a 'Timeout' exception if it does not
-- complete within the given timeout.
tryWithTimeout ::
    Transport      -- ^ Transport for running given Process.
    -> RemoteTable -- ^ RemoteTable for running given Process.
    -> Int         -- ^ Timeout value in nanoseconds.
    -> Process ()  -- ^ Process to run.
    -> IO ()
tryWithTimeout transport rtable t p =
   tryWithTimeoutIO transport rtable t (flip runProcess p)

-- | Runs the given 'IO' action and throws a 'Timeout' exception if it does not
-- complete within the given timeout.
tryWithTimeoutIO ::
    Transport      -- ^ Transport for running given Process.
    -> RemoteTable -- ^ RemoteTable for running given Process.
    -> Int         -- ^ Timeout value in nanoseconds.
    -> (LocalNode -> IO ())  -- ^ Action to run. It takes a newly created node
                             -- as argument.
    -> IO ()
tryWithTimeoutIO transport rtable t action =
    (maybe (throwIO Timeout) return =<<) $ timeout t $
      withLocalNode transport rtable action

-- | Throws 'AssertionFailed' exception when given value is 'False'.
assert :: Bool -> Process ()
assert True  = say "Assertion success."
assert False = throw $ AssertionFailed "Assertion fail."

assertMsg :: String -> Bool -> Process ()
assertMsg msg True = say $ "Assertion success: " ++ msg
assertMsg msg False = throw . AssertionFailed $ "Assertion fail: " ++ msg

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
    terminateProcesses (LocalNodeValid st) = do
      -- Trying to kill the management agent controller prevents other processes
      -- from terminating.
      let mxACPid = case localEventBus node of
                      MxEventBus pid _ _ _ -> pid
                      MxEventBusInitialising -> error "terminateLocalProcesses: The given node is not initialized."
          pids = delete mxACPid $ map processId $ Map.elems (st ^. localProcesses)
      mapM_ monitor pids
      mapM_ (flip exit "closing node") pids
      case mtimeout of
        Just t -> do
          timer <- spawnLocal $ void $ receiveTimeout t []
          void $ monitor timer
          let loop 0 = do
                exit timer "all process were terminated"
                receiveWait
                  [ match $ \(ProcessMonitorNotification _ _ _) -> return () ]
                maybe (return ())
                      (liftIO . killThread . processThread) $
                      (st ^. localProcessWithId (processLocalId mxACPid))
                return True
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
    terminateProcesses _ = return True

-- | Gets the path to the build folder inside the dist folder when called
-- by a program which resides there.
getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

-- | Bracket-like function for local node, it starts a node, performs
-- computation and closes node at the end.
withLocalNode :: Transport -> RemoteTable -> (LocalNode -> IO a) -> IO a
withLocalNode t rt = E.bracket  (newLocalNode t rt) closeLocalNode

-- | Bracket-like function for starting test on many nodes, it starts
-- nodes, performs computations and stops them at the end.
withLocalNodes :: Int
               -> Transport
               -> RemoteTable
               -> ([LocalNode] -> IO a)
               -> IO a
withLocalNodes 0 _t _rt f = f []
withLocalNodes n t rt f = withLocalNode t rt $ \node ->
    withLocalNodes (n - 1) t rt (f . (node :))
