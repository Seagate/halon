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
      , __remoteTable
      ) where

import HA.CallTimeout (callTimeout, mixedCallNodesTimeout)
import HA.NodeAgent.Messages
import HA.NodeAgent.Lookup (lookupNodeAgent,nodeAgentLabel)
import HA.Network.Address (Address,readNetworkGlobalIVar)
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types (HAEvent(..), EventId(..))
import HA.EventQueue.Producer (expiate)
import HA.Resources(Service(..),ServiceUncaughtException(..),Node(..))
import HA.Utils (forceSpine)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static (closureApply)
import Control.Distributed.Process.Serializable (Serializable)

import Control.Monad (when, void)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException(..))
import Data.Binary (Binary, encode)
import Data.Maybe (catMaybes, maybeToList)
import Data.ByteString (ByteString)
import Data.List (delete, nub, (\\))
import Data.Typeable (Typeable)
import Data.Word (Word64)
import GHC.Generics (Generic)

-- FIXME: What do all of these expire-related things have to do with the node agent?
data ExpireReason = forall why. Serializable why => ExpireReason why
  deriving (Typeable)

instance Show ExpireReason where
  show _ = "ExpireReason"

data ExpireException = ExpireException ExpireReason
  deriving (Typeable, Show)

instance Exception ExpireException

data UpdateNAState = UpdateNAState (CU NAState)
  deriving (Generic, Typeable)

-- | Closures of updates of values of type @a@.
type CU a = Closure (a -> a)

instance Binary UpdateNAState

expire :: Serializable a => a -> Process b
expire why = liftIO $ throwIO $ ExpireException $ ExpireReason why

-- | State of the node agent.
data NAState = NAState
    { nasEventCounter       :: Word64   -- ^ A counter used to tag events produced
                                        -- in the node.
    , nasReplicas           :: [NodeId] -- ^ The replicas we know.
    , nasPreferredReplica   :: Maybe NodeId -- ^ The node replicas suggest as access point.
    }
  deriving (Generic, Typeable)

-- This instance is not used but we need it so the 'remotable' splice below
-- is happy.
instance Binary NAState

updateNAS :: (NodeId, Maybe NodeId) -> NAState -> NAState
updateNAS (nid, mnid) nas =
                                  -- Force the spine so thunks don't accumulate.
    nas { nasReplicas           = forceSpine $ if elem nid $ nasReplicas nas
                                    then nid : delete nid (nasReplicas nas)
                                    -- The update is invalidated by a later
                                    -- update to the list of replicas.
                                    else nasReplicas nas
        , nasPreferredReplica   = mnid
        }

remotable [ 'updateNAS ]

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

-- | Because of GHC staging restrictions this code snippet needs
-- to be placed in a definition outside the quotation of 'remotableDecl'.
matchNASUpdate :: NAState -> Match NAState
matchNASUpdate nas = match $ \(UpdateNAState cNASupdate) ->
    fmap ($ nas) $ unClosure cNASupdate

-- | Because of GHC staging restrictions this code snippet needs
-- to be placed in a definition outside the quotation of 'remotableDecl'.
sendNAState :: ProcessId -> CU NAState -> Process ()
sendNAState pid = send pid . UpdateNAState

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
    nodeAgentProcess = go $ NAState 0 [] Nothing
      where
        go :: NAState -> Process a
        go nas = do
              self <- getSelfPid
              receiveWait
                [ match $ \(caller, UpdateEQNodes eqnids) -> do
                    send caller True
                    return $ nas
                      { nasReplicas = eqnids
                        -- Preserve the preferred replica only if it belongs
                        -- to the new list of nodes.
                      , nasPreferredReplica =
                          maybe Nothing
                                (\x -> if elem x eqnids
                                         then Just x
                                         else Nothing
                                ) $
                                nasPreferredReplica nas
                      }
                  -- Apply an update to the NA state.
                , matchNASUpdate nas
                  -- match a pre-serialized event sent from service
                , match $ \(caller, payload) -> do
                    when (null (nasReplicas nas)) $
                      say "Node Agent: Warning: Ignoring event because no EQs are registered"
                    let
                      event = HAEvent
                        { eventId      = EventId self (nasEventCounter nas)
                        , eventPayload = payload :: [ByteString]
                        -- FIXME: Solve properly the conflict with event tracking.
                        -- , eventHops    = []
                        , eventHops    = [self]
                        }
                      -- FIXME: Use well-defined timeouts.
                      softTimeout = 2000000
                      timeout = 3000000
                      nodes0 = nub $ take 1 (nasReplicas nas)
                                     ++  maybeToList (nasPreferredReplica nas)

                    -- Send the event to some replica.
                    result <- mixedCallNodesTimeout nodes0 (nasReplicas nas \\ nodes0) eventQueueLabel event softTimeout timeout
                    case result :: Maybe (NodeId, NodeId) of
                      Just (rnid, pnid) -> do
                        handleEQResponse self nas rnid pnid
                        send caller True
                        return $ nas { nasEventCounter = nasEventCounter nas + 1 }
                      Nothing -> do
                        send caller False
                        return nas
                ] >>= go

        -- The EQ response may suggest to contact another replica. This call
        -- handles the NA state update.
        --
        -- @handleEQResponse naPid naState responsiveNid preferredNid@
        --
        handleEQResponse :: ProcessId -> NAState -> NodeId -> NodeId -> Process ()
        handleEQResponse na nas rnid pnid =
          when (rnid /= head (nasReplicas nas)
                || Just pnid /= nasPreferredReplica nas
               ) $
            sendNAState na $ $(mkClosure 'updateNAS) $
              if rnid == pnid
              then (rnid, Nothing) -- The EQ sugested itself.
              else if elem pnid $ takeWhile (/=rnid) $ nasReplicas nas
                then (rnid, Just pnid)
                -- We have not tried reaching the preferred node yet.
                else (pnid, Just pnid)
    |] ]
