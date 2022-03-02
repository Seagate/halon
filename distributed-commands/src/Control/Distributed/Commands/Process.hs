-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Distributed commands for distributed-process.
--
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
module Control.Distributed.Commands.Process
  ( spawnNode
  , spawnNode_
  , spawnLocalNode
  , sendSelfNode
  , registerLogHook
  , redirectLogs
  , redirectLogsHere
  , copyLog
  , expectLog
  , expectTimeoutLog
  , copyFiles
  , copyFilesMove
  , systemThere
  , systemLocal
  , withHostNames
  , withHosts
  , __remoteTable
  , redirectLogsThere__tdict
    -- * Tracing
    -- $trace
  , mkTraceEnv
  , TraceEnv(..)
  , NodeHandle
  , handleGetInput
  , handleGetNodeId
  ) where

import Control.Distributed.Commands.Management
    ( Host
    , HostName
    )
import qualified Control.Distributed.Commands as C
    ( systemThere
    , systemThereAsUser
    , systemLocal
    )
import qualified Control.Distributed.Commands.Management as M

import Control.Concurrent as C (forkIO, newChan, writeChan, readChan)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
    ( remotable
    , mkClosure
    , sdictUnit
    )
import Control.Distributed.Process.Internal.Primitives (SayMessage(..))
import Control.Distributed.Process.Internal.Types (runLocalProcess)
import Control.Exception as E (evaluate, onException, SomeException, throwIO)
import qualified Control.Monad.Catch as C
import Control.Monad.Reader (ask, when)
import qualified Data.ByteString.Base64.Lazy as B64
import Data.Binary (decode, encode, Binary)
import qualified Data.ByteString.Lazy.Char8 as C8 (pack, unpack)
import Data.Function (fix)
import Data.IORef
import Data.List (isPrefixOf, isSuffixOf)
import Data.Foldable (forM_)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import System.Exit (ExitCode(..))
import System.Environment (lookupEnv, getEnvironment, setEnv)
import System.IO
import System.IO.Unsafe (unsafePerformIO)


-- | Sends all log messages in the local node to the given process.
redirectLogsThere :: ProcessId -> Process ()
redirectLogsThere pid = do
    Just logger <- whereis "logger"

    let loop = receiveWait
            [ match $ \msg -> do
                  send pid (msg :: SayMessage)
                  loop
            , matchAny $ \amsg -> do
                  forward amsg logger
                  loop ]

    reregister "logger" =<< spawnLocal loop

remotable [ 'redirectLogsThere ]

-- | @redirectLogs n to@ has all log messages produced by @n@ sent to the
-- process with the given identifier @to@.
--
redirectLogs :: NodeId -> ProcessId -> Process ()
redirectLogs n to = call sdictUnit n $ $(mkClosure 'redirectLogsThere) to

-- | @redirectLogsHere n@ has all log messages produced by @n@ sent to the
-- logger of the local node.
--
redirectLogsHere :: NodeId -> Process ()
redirectLogsHere n = whereis "logger" >>=
    maybe (die "redirectLogsHere: unkown local logger") (redirectLogs n)

-- | Used when calling 'spawnNode', it gathers the resulted 'NodeId' and
--   the action used to read input from the process.
data NodeHandle =
    NodeHandle
    { handleGetNodeId :: NodeId
    , handleGetInput  :: IO (Either ExitCode String)
      -- ^ Reads input from the process.
    }

data SpawnNodeId = SpawnNodeId ProcessId NodeId
  deriving (Typeable, Generic)

instance Binary SpawnNodeId

-- | @spawnNode h command@ launches @command@ on the host @h@.
--
-- @command@ is expected to spawn a Cloud Haskell node, and it
-- should send its 'NodeId' back to the caller with 'sendSelfNode' at the very
-- start.
--
-- All log messages are redirected to the node of the caller.
--
spawnNode :: HostName -> String -> Process NodeHandle
spawnNode h cmd =
    spawnNodeWith (maybe C.systemThere C.systemThereAsUser muser h) cmd
  where
    muser = if isLocalHost h then Nothing else Just "dev"

-- | Same as 'spawnNode' but returns a 'NodeId' instead.
spawnNode_ :: HostName -> String -> Process NodeId
spawnNode_ h = fmap handleGetNodeId . spawnNode h

-- | Sends the local 'NodeId' to the caller. Does nothing if the caller is not
-- 'spawnNode'.
sendSelfNode :: Process ()
sendSelfNode = do
  mpid <- liftIO $ lookupEnv "DC_CALLER_PID"
  case mpid of
    Nothing   -> return ()
    Just epid -> do
      pid <- liftIO $ evaluate
                       (decode $ either error id $ B64.decode $ C8.pack epid)
               `E.onException` putStrLn "failed decoding spawnNode pid"
      self <- getSelfPid
      getSelfNode >>= send pid . SpawnNodeId self
      expect

{-# NOINLINE spawnIdGen #-}
spawnIdGen :: IORef Int
spawnIdGen = unsafePerformIO $ newIORef 0

-- | Like 'spawnNode' but takes as argument the IO command used to spawn the
-- node.
spawnNodeWith :: (String -> IO (IO (Either ExitCode String)))
              -> String
              -> Process NodeHandle
spawnNodeWith ioSpawn cmd = do
    pid <- getSelfPid
    getLine_cmd <- liftIO $ ioSpawn $
      "export DC_CALLER_PID=" ++ C8.unpack (B64.encode $ encode pid) ++ "; " ++
      cmd
    -- The following try handles the exception that would result when the caller
    -- interrupts the call because it takes too long.
    enid <- C.try expect
    spawnId <- liftIO $ atomicModifyIORef' spawnIdGen $ \i -> (i + 1, i)
    let spawnLog = hPutStrLn stderr . (++) ("spawnNode(" ++ show spawnId ++ ")")
    case enid of
      Left e -> liftIO $ do
        fix $ \loop -> getLine_cmd >>= either print (\x -> putStrLn x >> loop)
        spawnLog $ ": The command " ++ show cmd ++ " did not sent a NodeId."
        throwIO (e :: SomeException)
      Right (SpawnNodeId sender nid) -> do
        redirectLogsHere nid
        usend sender ()
        liftIO $ spawnLog $ " started: " ++ cmd
        dup <- liftIO $ C.newChan
        _ <- liftIO $ forkIO $ fix $ \loop -> do
          eline <- getLine_cmd
          writeChan dup eline
          case eline of
            Left ec -> spawnLog $ " terminated: " ++ show ec
            Right line -> spawnLog (": " ++ line) >> loop
        return $ NodeHandle nid (readChan dup)

isLocalHost :: String -> Bool
isLocalHost h = h == "localhost" || "127." `isPrefixOf` h

-- | Like @spawnNode@ but spawns the node in the local host.
spawnLocalNode :: String -> Process NodeId
spawnLocalNode cmd = handleGetNodeId <$> spawnNodeWith C.systemLocal cmd

-- | Intercepts 'say' messages from processes as a crude way to know that an
-- action following an asynchronous send has completed.
registerLogHook ::
    (SayMessage -> Process ())
    -- ^ Intercepter hook. Takes a @SayMessage@ message sent with 'say'
    -> Process ()
registerLogHook hook = do
    Just logger <- whereis "logger"

    let loop = receiveWait
            [ match $ \msg -> do
                  hook msg
                  send logger msg
                  loop
            , matchAny $ \amsg -> do
                  forward amsg logger
                  loop ]

    reregister "logger" =<< spawnLocal loop

-- | @copyLog p pid@ copies local log messages satisfying predicate @p@ to
-- to the process with identifier @pid@.
--
copyLog :: (SayMessage -> Bool)
        -> ProcessId
        -> Process ()
copyLog p pid = registerLogHook $ \msg -> when (p msg) $ send pid msg

-- | Blocks until a message copy produced by @copyLog@ is received
-- while originating from any of the given nodes.
--
expectLog :: [NodeId] -> (String -> Bool) -> Process ()
expectLog nids p = receiveWait
    [ matchIf (\(SayMessage _ pid msg) ->
                elem (processNodeId pid) nids && p msg
              ) $
              const $ return ()
    ]

-- | Like 'expectLog' but returns @False@ if the given timeout expires.
expectTimeoutLog :: Int -> [NodeId] -> (String -> Bool) -> Process Bool
expectTimeoutLog t nids p = receiveTimeout t
    [ matchIf (\(SayMessage _ pid msg) ->
                elem (processNodeId pid) nids && p msg
              ) $
              const $ return ()
    ] >>= maybe (return False) (const $ return True)

-- | Copies files from one host to others.
copyFiles :: HostName -> [HostName] -> [(FilePath, FilePath)] -> Process ()
copyFiles from to files = liftIO $ M.copyFiles from to files

-- | Copies files from one host to others through help of @mv@: see
-- 'M.copyFilesMove'.
copyFilesMove :: HostName -> [HostName] -> [(FilePath, FilePath, FilePath)] -> Process ()
copyFilesMove from to files = liftIO $ M.copyFilesMove from to files

-- | @systemThere ms command@ runs @command@ in a shell on hosts @ms@ and waits
-- until it completes.
systemThere :: [HostName] -> String -> Process ()
systemThere ms cmd = liftIO $ M.systemThere ms cmd

-- | @systemLocal command@ runs @command@ in a shell on the local hosts and
-- waits until it completes.
systemLocal :: String -> Process ()
systemLocal cmd = liftIO $ M.systemLocal cmd

-- | @withHosts cp n action@ creates @n@ hosts from provider @cp@
-- and then it executes the given @action@. Upon termination of the actions
-- the hosts are destroyed.
withHosts :: M.Provider -> Int -> ([Host] -> Process a) -> Process a
withHosts cp n action = do
    lproc <- ask
    liftIO $ M.withHosts cp n $ runLocalProcess lproc . action

-- | Like @withHosts@ but it passes 'HostName's instead of 'Host's to the
-- given action.
withHostNames :: M.Provider -> Int -> ([HostName] -> Process a) -> Process a
withHostNames cp n action = do
    lproc <- ask
    liftIO $ M.withHostNames cp n $ runLocalProcess lproc . action

-- $tracing
-- Sometimes users are interested in gathering tracing events, it is
-- possible to set tracing options using environment variables.
--
-- distributed-commands can enable tracing on all processes. This is done by
-- propagating the trace-related environment variables to to the remote hosts
-- and having them trace to a file. Then after the test completes, it can gather
-- all the files that were created. See 'TraceEnv' and 'mkTraceEnv'.
--
-- Tracing is enabled by setting the environment variables
-- @DISTRIBUTED_PROCESS_TRACE_FLAGS@ and @DISTRIBUTED_PROCESS_TRACE_FILE@ as
-- explained in
-- <http://hackage.haskell.org/package/distributed-process/docs/Control-Distributed-Process-Debug.html>.

-- | A trace environment is defined by a function to spawn processes with
-- tracing enabled, and a function to collect the trace files that these
-- processes produce.
data TraceEnv = TraceEnv
      { traceSpawnNode   :: String -> HostName -> String -> Process NodeId
      , traceGatherFiles :: Process ()
      }

-- | Creates 'TraceEnv' that allow to run traced nodes on remote hosts and
-- gather resulting the files.
--
-- It is intented to be used as:
--
-- > TraceEnv spawnNode' gatherFiels <- mkTraceEnv
--
-- **Note.** Tracing to the console is not suported yet. mkTraceEnv expects
-- tracing to files. All files are given the '.trace' suffix, to make them easy
-- to recognize.
--
-- **Note.** If 'mkTraceEnv' is run after 'newLocalNode', the trace file of the
-- local node will be missing the '.trace' suffix.
mkTraceEnv :: IO TraceEnv
mkTraceEnv = do
    env <- getEnvironment
    case "DISTRIBUTED_PROCESS_TRACE_FLAGS" `lookup` env of
      Nothing -> return envNoTrace
      Just t  -> do
        case "DISTRIBUTED_PROCESS_TRACE_FILE" `lookup` env of
          Nothing -> return envNoTrace
          Just s  -> do
            let s' = normalize s
            st <- newIORef []
            setEnv "DISTRIBUTED_PROCESS_TRACE_FILE" s'
            return $ TraceEnv (withTraceFile st t s')
                              (do fls <- liftIO $ readIORef st
                                  forM_ fls $ \(node,file) ->
                                    copyFiles node ["localhost"] [(file, ".")]) -- XXX: it's possible to group files here
  where
    spawnNodeId h cmd = fmap handleGetNodeId $ spawnNode h cmd
    envNoTrace = TraceEnv (const spawnNodeId) (return ())
    normalize t
      | ".trace" `isSuffixOf` t = t
      | otherwise = t ++ ".trace"
    withTraceFile storage flags suffix prefix node cmd = do
      let file = prefix ++ '.':suffix
      liftIO $ modifyIORef' storage ((node,file):)
      nh <- spawnNode node $
              unwords [ "DISTRIBUTED_PROCESS_TRACE_FLAGS=" ++ flags
                      , " DISTRIBUTED_PROCESS_TRACE_FILE=" ++ file
                      , cmd
                      ]
      return $ handleGetNodeId nh
