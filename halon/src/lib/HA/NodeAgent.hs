-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.

{-# LANGUAGE TemplateHaskell, ExistentialQuantification #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.NodeAgent
      ( module HA.NodeAgent.Messages
      , Service(..)
      , service
      , nodeAgent
      , updateEQAddresses
      , updateEQNodes
      , expire
      , __remoteTableDecl
      ) where

import HA.CallTimeout (callTimeout)
import HA.NodeAgent.Messages
import HA.NodeAgent.Lookup (lookupNodeAgent,nodeAgentLabel)
import HA.Network.Address (Address,readNetworkGlobalIVar)
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types (HAEvent(..), EventId(..))
import HA.EventQueue.Producer (expiate, sendHAEvent)
import HA.Resources(Service(..),ServiceUncaughtException(..),Node(..))
import HA.Utils (forceSpine)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static (closureApply)
import Control.Distributed.Process.Serializable (Serializable)

import Control.Monad (when, void)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException(..))
import Data.Binary (encode)
import Data.Maybe (catMaybes)
import Data.ByteString (ByteString)
import Data.List (delete)
import Data.Typeable (Typeable)
import Data.Word (Word64)
import GHC.Generics (Generic)


sayNA :: String -> Process ()
sayNA s = say $ "Node Agent: " ++ s


-- FIXME: What do all of these expire-related things have to do with the node agent?
data ExpireReason = forall why. Serializable why => ExpireReason why
  deriving (Typeable)

instance Show ExpireReason where
  show _ = "ExpireReason"

data ExpireException = ExpireException ExpireReason
  deriving (Typeable, Show)

instance Exception ExpireException

expire :: Serializable a => a -> Process b
expire why = liftIO $ throwIO $ ExpireException $ ExpireReason why


sendEQ :: NodeId -> HAEvent [ByteString] -> Int -> Process (Maybe NodeId)
sendEQ node msg timeOut = do
    whereisRemoteAsync node eventQueueLabel
    mpid <- receiveTimeout timeOut [
              matchIf (\(WhereIsReply name' mpid') ->
                          name' == eventQueueLabel && maybe False ((==)node . processNodeId) mpid')
                      (\(WhereIsReply _ mpid') -> return mpid')
            ]
    case mpid of
      Just (Just pid) ->
        -- callLocal creates a temporary mailbox so late responses don't leak or
        -- interfere with other calls.
        callLocal $ do
          sendHAEvent pid msg
          expectTimeout timeOut
      _ -> return Nothing

serialCall :: [NodeId] -> HAEvent [ByteString] ->
              Int -> Process (Maybe (NodeId, NodeId))
serialCall           []   _       _ = return Nothing
serialCall (node:nodes) msg timeOut = do
    ret <- sendEQ node msg timeOut
    case ret of
      Just b -> return $ Just (node, b)
      _ -> serialCall nodes msg timeOut

-- FIXME: What is going on in this function?
-- Are @mns@ the process ids of all node agents on the network?
-- Are @nodes@ the node ids of all node agents on the network?
-- Is pid the process id of the node agent to be updated?
updateEQAddresses :: ProcessId -> [Address] -> Process Bool
updateEQAddresses pid addrs =
  do network <- liftIO readNetworkGlobalIVar
     mns <- mapM (lookupNodeAgent network) addrs
     let nodes = map processNodeId $ catMaybes mns
     updateEQNodes pid nodes

-- FIXME: Use a well-defined timeout.
updateEQNodes :: ProcessId -> [NodeId] -> Process Bool
updateEQNodes pid nodes =
    maybe False id <$> callTimeout pid (UpdateEQNodes nodes) timeout
  where
    timeout = 3000000


data State = State
    { naEventCount :: Word64   -- ^ Number of events successfully forwarded to an EQ.
    , naEQNodes    :: [NodeId] -- ^ Nodes of known EQs.
    }
  deriving (Generic, Typeable)

emptyState :: State
emptyState = State
    { naEventCount = 0
    , naEQNodes    = []
    }

incrementEventCount :: State -> State
incrementEventCount state =
    state { naEventCount = naEventCount state + 1 }

setEQNodes :: State -> [NodeId] -> State
setEQNodes state nids =
    state { naEQNodes = forceSpine nids }

setPreferredEQNode :: State -> NodeId -> State
setPreferredEQNode state nid = setEQNodes state nids
  where
    nids = nid : delete nid (naEQNodes state)


remotableDecl [ [d|

    -- FIXME: What is going on in these functions?
    sdictServiceInfo :: SerializableDict (String, Closure (Process ()))
    sdictServiceInfo = SerializableDict

    serviceWrapper :: (String, Closure (Process ())) -> Process () -> Process ()
    serviceWrapper (name,cp) p = do
        self <- getSelfPid
        either (\(ProcessRegistrationException _) -> return ()) (const go) =<<
            try (register name self)
      where
        generalExpiate desc = do
          mbpid <- whereis nodeAgentLabel
          case mbpid of
             Nothing -> error "NodeAgent is not registered."
             Just na -> expiate $ ServiceUncaughtException (Node na) (Service name cp) desc
        myCatches n handler =
           (n >> handler (generalExpiate "Service died without exception")) `catches`
             [ Handler $ \(ExpireException (ExpireReason why)) -> handler $ expiate why,
               Handler $ \(SomeException e) -> handler $ generalExpiate $ show e ]
        go = myCatches p $ \res -> do
               self <- getSelfPid
               void $ spawnLocal $ do
                 ref <- monitor self

                 -- Wait for main service process to die before sending expiate. This will
                 -- ensure that any linked child processes are notified not after expiate.
                 receiveWait [
                    matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == ref)
                            (const $ return ()) ]
                 res

    -- | Wrapper function for services. Use as follows:
    --
    -- > remoteDecl [ [d|
    -- >   foo = service "foo" $(mkStaticClosure 'fooProcess)
    -- >
    -- >   fooProcess = ...
    -- >   |] ]
    --
    service :: String -> Closure (Process ()) -> Service
    service name p =
        Service name $
        $(mkStaticClosure 'serviceWrapper) `closureApply`
        closure (staticDecode $(mkStatic 'sdictServiceInfo)) (encode (name,p)) `closureApply`
        p

    -- | The master node agent process.
    nodeAgent :: Service
    nodeAgent = service nodeAgentLabel $(mkStaticClosure 'nodeAgentProcess)

    nodeAgentProcess :: Process ()
    nodeAgentProcess = go emptyState
      where
        go :: State -> Process a
        go state = do
              self <- getSelfPid
              receiveWait
                [ match $ \(caller, UpdateEQNodes nids) -> do
                    when (null nids) $
                      sayNA "Warning: Unregistering all EQs"
                    send caller True
                    return (setEQNodes state nids)
                , match $ \(caller, content) -> do
                    when (null (naEQNodes state)) $
                      sayNA "Warning: Ignoring event because no EQs are registered"
                    let timeOut = 3000000
                        ev = HAEvent { eventId = EventId self (naEventCount state)
                                     , eventPayload = content :: [ByteString]
                                     , eventHops    = [] }
                    -- FIXME: Perhaps demote non-responsive EQs.
                    ret <- serialCall (naEQNodes state) ev timeOut
                    case ret :: Maybe (NodeId, NodeId) of
                      Just (_, nid) | nid `elem` naEQNodes state -> do
                        send caller True
                        return (incrementEventCount (setPreferredEQNode state nid))
                      Just (_, _) -> do
                        send caller True
                        sayNA "Warning: Ignoring preferred EQ because it is not registered"
                        return (incrementEventCount state)
                      Nothing -> do
                        send caller False
                        sayNA "Warning: Event timed out"
                        return state
                ] >>= go
    |] ]
