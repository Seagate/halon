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
  , spawnNodes
  , printNodeId
  , registerLogHook
  , redirectLogs
  , redirectLogsHere
  , copyLog
  , expectLog
  , copyFiles
  , systemThere
  , withHostNames
  , withHosts
  , __remoteTable
  ) where

import Control.Distributed.Commands.Management
    ( Host
    , HostName
    )
import qualified Control.Distributed.Commands as C
    ( systemThere
    , systemThereAsUser
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
import Data.List (isPrefixOf)
import System.IO (hFlush, stdout)


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
spawnNode :: HostName -> String -> Process NodeId
spawnNode h = liftIO . spawnNodeIO h

-- | Prints the given 'NodeId' in the standard output.
printNodeId :: NodeId -> IO ()
printNodeId n = do print $ encode n
                   -- XXX: an extra line of outputs seems to be needed when
                   -- programs are run through ssh so the output is actually
                   -- received.
                   putStrLn ""
                   hFlush stdout

spawnNodeIO :: HostName -> String -> IO NodeId
spawnNodeIO h cmd = do
    getLine_cmd <- maybe C.systemThere C.systemThereAsUser muser h cmd
    mnode <- getLine_cmd
    case mnode of
      Left _ -> error $ "The command \"" ++ cmd ++ "\" did not print a NodeId."
      Right n  -> case reads n of
        (bs,"") : _ -> return $ decode (bs :: ByteString)
        _           -> error $ "Couldn't parse node id: " ++ n
  where
    muser = if isLocalHost h then Nothing else Just "dev"

isLocalHost :: String -> Bool
isLocalHost h = h == "localhost" || "127." `isPrefixOf` h

-- | Like @spawnNode@ but spawns multiple nodes in parallel.
--
-- XXX: This is a temporary function until there is an 'async' implementation
-- for 'Process' which will allow to define it in terms of 'spawnNode'.
--
spawnNodes :: [HostName] -> String -> Process [NodeId]
spawnNodes hs cmd = liftIO $ mapConcurrently (flip spawnNodeIO cmd) hs

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

-- | Copies files from one host to others.
copyFiles :: HostName -> [HostName] -> [(FilePath, FilePath)] -> Process ()
copyFiles from to files = liftIO $ M.copyFiles from to files

-- | @systemThere ms command@ runs @command@ in a shell on hosts @ms@ and waits
-- until it completes.
systemThere :: [HostName] -> String -> Process ()
systemThere ms cmd = liftIO $ M.systemThere ms cmd

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
