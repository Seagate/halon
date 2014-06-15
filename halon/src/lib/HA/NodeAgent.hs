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

import HA.CallTimeout (callLocal, callTimeout, ncallRemoteAnyPreferTimeout)
import HA.NodeAgent.Messages
import HA.NodeAgent.Lookup (lookupNodeAgent,nodeAgentLabel)
import HA.Network.Address (Address,readNetworkGlobalIVar)
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types (HAEvent(..), EventId(..))
import HA.EventQueue.Producer (expiate)
import HA.Resources(Service(..),ServiceUncaughtException(..),Node(..))
import Control.SpineSeq (spineSeq)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static (closureApply)
import Control.Distributed.Process.Serializable (Serializable)

import Control.Monad (when, void)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException(..))
import Data.Binary (encode)
import Data.Maybe (catMaybes, maybeToList)
import Data.ByteString (ByteString)
import Data.List (delete, nub, (\\))
import Data.Typeable (Typeable)
import Data.Word (Word64)

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

-- | State of the node agent.
data NAState = NAState
    { nasEventCounter       :: Word64   -- ^ A counter used to tag events produced
                                        -- in the node.
    , nasReplicas           :: [NodeId] -- ^ The replicas we know.
    , nasPreferredReplica   :: Maybe NodeId
       -- ^ The node replicas suggest as access point.
       --
       -- This field is used as a reminder for the NA to poll the preferred
       -- replica until it replies. Therefore it obeys the following invariant:
       --
       -- This field is @Just nid@ for as long as @nid@ is the
       -- preferred replica and the NA hasn't received an acknowledgement
       -- from it sooner than from other replicas.
       --
       -- When the preferred replica responds fast enough, this field becomes
       -- Nothing.
    }
  deriving (Typeable)

-- NOTE: This function expects to only be used with nodes which are part of the
-- tracking station, as it takes the addresses of nodes which are running a NA,
-- converts the addresses to node ids, and passes the node ids to updateEQNodes,
-- which expects node ids of the tracking station nodes which are running an EQ.
updateEQAddresses :: ProcessId -> [Address] -> Process Bool
updateEQAddresses pid addrs =
  do network <- liftIO readNetworkGlobalIVar
     mns <- mapM (lookupNodeAgent network) addrs
     let nodes = map processNodeId $ catMaybes mns
     updateEQNodes pid nodes

-- FIXME: Use a well-defined timeout.
updateEQNodes :: ProcessId -> [NodeId] -> Process Bool
updateEQNodes pid nodes =
    maybe False id <$> callLocal (callTimeout timeout pid (UpdateEQNodes nodes))
  where
    timeout = 3000000

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
                      preferNodes = nub $
                        maybeToList (nasPreferredReplica nas) ++
                        take 1 (nasReplicas nas)
                      nodes = nasReplicas nas \\ preferNodes

                    -- Send the event to some replica.
                    result <- callLocal $
                      ncallRemoteAnyPreferTimeout softTimeout timeout
                                                  preferNodes nodes
                                                  eventQueueLabel event
                    case result :: Maybe (NodeId, NodeId) of
                      Just (rnid, pnid) -> do
                        send caller True
                        return $ (handleEQResponse nas rnid pnid)
                                   { nasEventCounter = nasEventCounter nas + 1 }
                      Nothing -> do
                        send caller False
                        return nas
                ] >>= go

        -- The EQ response may suggest to contact another replica. This function
        -- handles the NA state update.
        --
        -- @handleEQResponse naState responsiveNid preferredNid@
        --
        handleEQResponse :: NAState -> NodeId -> NodeId -> NAState
        handleEQResponse nas rnid pnid =
          if (rnid /= head (nasReplicas nas)
              || Just pnid /= nasPreferredReplica nas
             ) then
            updateNAS nas $
              if rnid == pnid
              then (rnid, Nothing) -- The EQ sugested itself.
              else if rnid == head (nasReplicas nas)
                then (pnid, Just pnid) -- Likely we have not tried reaching the preferred node yet.
                else (rnid, Just pnid) -- The preferred replica did not respond soon enough.
          else
            nas

        updateNAS :: NAState -> (NodeId, Maybe NodeId) -> NAState
        updateNAS nas (nid, mnid) =
                                  -- Force the spine so thunks don't accumulate.
          nas { nasReplicas           = spineSeq $ if elem nid $ nasReplicas nas
                                          then nid : delete nid (nasReplicas nas)
                                          -- The update is invalidated by a later
                                          -- update to the list of replicas.
                                          else nasReplicas nas
              , nasPreferredReplica   = mnid
              }


    |] ]
