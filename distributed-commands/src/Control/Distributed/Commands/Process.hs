-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Distributed commands for distributed-process.
--
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
module Control.Distributed.Commands.Process
  ( spawnNode
  , spawnNode_
  , spawnLocalNode
  , spawnNodes
  , printNodeId
  , registerLogHook
  , redirectLogs
  , redirectLogsHere
  , copyLog
  , expectLog
  , expectTimeoutLog
  , copyFiles
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

import Control.Concurrent.Async.Lifted
import Control.Distributed.Process
    ( spawnLocal
    , call
    , whereis
    , reregister
    , send
    , matchAny
    , match
    , matchIf
    , forward
    , ProcessId
    , Process
    , receiveWait
    , receiveTimeout
    , NodeId
    , liftIO
    , processNodeId
    , die
    )
import Control.Distributed.Process.Closure
    ( remotable
    , mkClosure
    , sdictUnit
    )
import Control.Distributed.Process.Internal.Types (runLocalProcess)
import Control.Monad.Reader (ask, when)
import Data.Binary (decode, encode)
import Data.ByteString.Lazy (ByteString)
import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.List (isPrefixOf, isSuffixOf)
import Data.Foldable (forM_)
import System.Exit (ExitCode(..))
import System.IO (hFlush, stdout)
import System.Environment (getEnvironment, setEnv)

-- | Used when calling 'spawnNode', it gathers the resulted 'NodeId' and
--   the action used to read input from the process.
data NodeHandle =
    NodeHandle
    { handleGetNodeId :: NodeId
    , handleGetInput  :: IO (Either ExitCode String)
      -- ^ Reads input from the process.
    }

-- | @spawnNode h command@ launches @command@ on the host @h@.
--
-- @command@ is expected to spawn a Cloud Haskell node, and it
-- should print its 'NodeId' on the very first line of the standard
-- output as
--
-- > print (Data.Binary.encode nodeId)
--
-- 'printNodeId' can be used for that purpose.
--
spawnNode :: HostName -> String -> Process NodeHandle
spawnNode h = liftIO . spawnNodeIO h

-- | Same as 'spawnNode' but returns a 'NodeId' instead.
spawnNode_ :: HostName -> String -> Process NodeId
spawnNode_ h = fmap handleGetNodeId . spawnNode h

-- | Prints the given 'NodeId' in the standard output.
printNodeId :: NodeId -> IO ()
printNodeId n = do print $ encode n
                   -- XXX: an extra line of outputs seems to be needed when
                   -- programs are run through ssh so the output is actually
                   -- received.
                   putStrLn ""
                   hFlush stdout

spawnNodeIO :: HostName -> String -> IO NodeHandle
spawnNodeIO h cmd = do
    getLine_cmd <- maybe C.systemThere C.systemThereAsUser muser h cmd
    mnode <- getLine_cmd
    case mnode of
      Left _ -> error $ "The command \"" ++ cmd ++ "\" did not print a NodeId."
      Right n  -> case reads n of
        (bs,"") : _ -> return $ NodeHandle (decode (bs :: ByteString))
                                           getLine_cmd
        _           -> error $ "Couldn't parse node id. \"" ++ cmd ++
                               "\" produced: " ++ n
  where
    muser = if isLocalHost h then Nothing else Just "dev"

isLocalHost :: String -> Bool
isLocalHost h = h == "localhost" || "127." `isPrefixOf` h

-- | Like @spawnNode@ but spawns multiple nodes in parallel.
--
-- XXX: This is a temporary function until there is an 'async' implementation
-- for 'Process' which will allow to define it in terms of 'spawnNode'.
--
spawnNodes :: [HostName] -> String -> Process [NodeHandle]
spawnNodes hs cmd = liftIO $ mapConcurrently (flip spawnNodeIO cmd) hs

-- | Like @spawnNode@ but spawns the node in the local host.
spawnLocalNode :: String -> Process NodeId
spawnLocalNode cmd = liftIO $ do
    getLine_cmd <- C.systemLocal cmd
    mnode <- getLine_cmd
    case mnode of
      Left _ -> error $ "The command \"" ++ cmd ++ "\" did not print a NodeId."
      Right n  -> case reads n of
        (bs,"") : _ -> return $ decode (bs :: ByteString)
        _           -> error $ "Couldn't parse node id. \"" ++ cmd ++
                               "\" produced: " ++ n

-- | Intercepts 'say' messages from processes as a crude way to know that an
-- action following an asynchronous send has completed.
registerLogHook ::
    ((String, ProcessId, String) -> Process ())
    -- ^ Intercepter hook. Takes triplet @(timestamp, process, message)@
    -- message sent with 'say'
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

-- | Sends all log messages in the local node to the given process.
redirectLogsThere :: ProcessId -> Process ()
redirectLogsThere pid = do
    Just logger <- whereis "logger"

    let loop = receiveWait
            [ match $ \msg -> do
                  send pid (msg :: (String, ProcessId, String))
                  loop
            , matchAny $ \amsg -> do
                  forward amsg logger
                  loop ]

    reregister "logger" =<< spawnLocal loop


remotable [ 'redirectLogsThere ]


-- | @redirectLogsHere n to@ has all log messages produced by @n@ sent to the
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


-- | @copyLog p pid@ copies local log messages satisfying predicate @p@ to
-- to the process with identifier @pid@.
--
copyLog :: ((String, ProcessId, String) -> Bool)
        -> ProcessId
        -> Process ()
copyLog p pid = registerLogHook $ \msg -> when (p msg) $ send pid msg

-- | Blocks until a message copy produced by @copyLog@ is received
-- while originating from any of the given nodes.
--
expectLog :: [NodeId] -> (String -> Bool) -> Process ()
expectLog nids p = receiveWait
    [ matchIf (\(_ :: String, pid, msg) ->
                elem (processNodeId pid) nids && p msg
              ) $
              const $ return ()
    ]

-- | Like 'expectLog' but returns @False@ if the given timeout expires.
expectTimeoutLog :: Int -> [NodeId] -> (String -> Bool) -> Process Bool
expectTimeoutLog t nids p = receiveTimeout t
    [ matchIf (\(_ :: String, pid, msg) ->
                elem (processNodeId pid) nids && p msg
              ) $
              const $ return ()
    ] >>= maybe (return False) (const $ return True)

-- | Copies files from one host to others.
copyFiles :: HostName -> [HostName] -> [(FilePath, FilePath)] -> Process ()
copyFiles from to files = liftIO $ M.copyFiles from to files

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
-- **Note.** Since spawnNode reads the 'NodeId' from the standard output,
-- tracing to the console is not suported. mkTraceEnv expects tracing to files.
-- All files are given the '.trace' suffix, to make them easy to recognize.
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
