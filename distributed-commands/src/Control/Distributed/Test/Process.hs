-- | Test interface extensions for distributed-process.
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
module Control.Distributed.Test.Process
  ( spawnNode
  , spawnNodes
  , registerLogInterceptor
  , copyLog
  , allMessages
  , expectLog
  , copyFilesTo
  , runIn
  , withMachineIPs
  , withMachines
  , __remoteTable
  ) where

import Control.Distributed.Commands (runCommand)
import Control.Distributed.Test (Machine, IP(..), CloudProvider)
import qualified Control.Distributed.Test as Test

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
    , getSelfPid
    , Closure
    , processNodeId
    )
import Control.Distributed.Process.Closure
    ( remotable
    , mkClosure
    , mkStaticClosure
    , sdictUnit
    )
import Control.Distributed.Static (closureApply)
import Control.Distributed.Process.Internal.Types (runLocalProcess)
import Control.Monad.Reader (ask, forM, when)
import Data.Binary (decode)
import Data.ByteString.Lazy (ByteString)
import Data.List (isPrefixOf)


-- | @spawnNode h command@ launches @command@ in the host @h@.
--
-- @command@ is expected to spawn a Cloud Haskell node, and it
-- should print its 'NodeId' in the very first line of the standard
-- output.
--
spawnNode :: IP -> String -> Process NodeId
spawnNode ip = liftIO . spawnNodeIO ip

spawnNodeIO :: IP -> String -> IO NodeId
spawnNodeIO (IP h) cmd = do
    getLine_cmd <- runCommand muser h cmd
    mnode <- getLine_cmd
    case mnode of
      Nothing -> error $ "The command \"" ++ cmd ++ "\" did not print a NodeId."
      Just n  -> case reads n of
        (bs,"") : _ -> return $ decode (bs :: ByteString)
        _           -> error $ "Couldn't parse node id: " ++ n
  where
    muser = if isLocalHost h then Nothing else Just "dev"

isLocalHost :: String -> Bool
isLocalHost h = h == "localhost" || "127.0." `isPrefixOf` h

-- | Like @spawnNode@ but spawns multiple nodes in parallel.
spawnNodes :: [IP] -> String -> Process [NodeId]
spawnNodes ips cmd = liftIO $
    forM ips (async . flip spawnNodeIO cmd) >>= mapM wait

-- | Intercepts 'say' messages from processes as a crude way to know that an
-- action following an asynchronous send has completed.
registerInterceptor ::
    () -- ^ Prevents remotable from requiring a Binary instance for the
       -- second argument.
    -> (ProcessId -> String -> Process ())
    -- ^ Intercepter hook. Takes 'String' message sent with 'say'
    -> Process ()
registerInterceptor () hook = do
    Just logger <- whereis "logger"

    let loop = receiveWait
            [ match $ \(msg@(_, pid, string) :: (String, ProcessId, String)) -> do
                  hook pid string
                  send logger msg
                  loop
            , matchAny $ \amsg -> do
                  forward amsg logger
                  loop ]

    reregister "logger" =<< spawnLocal loop

-- | @forwardWhen to p from msg@ forwards messages from process @from@ to
-- process @to@ when they satisfy predicate @p@.
--
-- Messages are forwarded as @(from, msg)@.
--
forwardWhen :: ProcessId
            -> (String -> Bool)
            -> ProcessId
            -> String
            -> Process ()
forwardWhen to p from msg = when (p msg) $ send to (from, msg)

allMessages' :: String -> Bool
allMessages' = const True

remotable [ 'registerInterceptor, 'forwardWhen, 'allMessages' ]

-- | @registerLogInterceptor m hook@ intercepts 'say' messages from
-- processes in the given node.
registerLogInterceptor :: NodeId
                       -> Closure (ProcessId -> String -> Process ())
                       -> Process ()
registerLogInterceptor nid hook = call sdictUnit nid $
    $(mkClosure 'registerInterceptor) () `closureApply` hook

-- | @copyLog n p@ copies 'say' messages from processes in node @n@
-- which satisfy predicate @p@.
--
-- The message copies are sent to the caller process as messages with
-- type @(ProcessId, String)@ where the @ProcessId@ identifies the node
-- where the message originated.
--
copyLog :: NodeId -> Closure (String -> Bool) -> Process ()
copyLog nid p = getSelfPid >>= \self ->
    registerLogInterceptor nid $ $(mkClosure 'forwardWhen) self `closureApply` p

-- | A predicate which accepts all messages.
allMessages :: Closure (String -> Bool)
allMessages = $(mkStaticClosure 'allMessages')

-- | Blocks until a message copy produced by @copyLog@ is received
-- while originating from any of the given nodes.
--
expectLog :: [NodeId] -> (String -> Bool) -> Process ()
expectLog nids p = receiveWait
    [ matchIf (\(pid, msg) -> elem (processNodeId pid) nids && p msg) $
              const $ return ()
    ]

-- | Copies files from one machine to others.
copyFilesTo :: IP -> [IP] -> [(FilePath, FilePath)] -> Process ()
copyFilesTo from to files = liftIO $ Test.copyFilesTo from to files

-- | @runIn ms command@ runs @command@ in a shell in machines @ms@ and waits
-- until it completes.
runIn :: [IP] -> String -> Process ()
runIn ms cmd = liftIO $ Test.runIn ms cmd

-- | @withMachines cp n action@ creates @n@ machines from provider @cp@
-- and then it executes the given @action@. Upon termination of the actions
-- the machines are destroyed.
withMachines :: CloudProvider -> Int -> ([Machine] -> Process a) -> Process a
withMachines cp n action = do
    lproc <- ask
    liftIO $ Test.withMachines cp n $ runLocalProcess lproc . action

-- | Like @withMachines@ but it passes 'IP's instead of 'Machines' to the
-- given action.
withMachineIPs :: CloudProvider -> Int -> ([IP] -> Process a) -> Process a
withMachineIPs cp n action = do
    lproc <- ask
    liftIO $ Test.withMachineIPs cp n $ runLocalProcess lproc . action
