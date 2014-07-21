-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.

{-# LANGUAGE TemplateHaskell, ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.NodeAgent
      ( module HA.NodeAgent.Messages
      , NodeAgentConf(..)
      , Service(..)
      , service
      , naConfigDict
      , naConfigDict__static
      , nodeAgent
      , updateEQAddresses
      , updateEQNodes
      , expire
      , HA.NodeAgent.__remoteTable
      , HA.NodeAgent.__remoteTableDecl
      ) where

import HA.CallTimeout (callLocal, callTimeout, ncallRemoteAnyPreferTimeout)
import HA.NodeAgent.Messages
import HA.NodeAgent.Lookup (lookupNodeAgent,nodeAgentLabel)
import HA.Network.Address (Address,readNetworkGlobalIVar)
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types (HAEvent(..), EventId(..))
import HA.EventQueue.Producer (expiate)
import HA.Resources(Node(..))
import HA.ResourceGraph hiding (null)
import HA.Service
import Control.SpineSeq (spineSeq)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static (
    closureApply
  , staticApply
  , closureApplyStatic
  )
import Control.Distributed.Process.Serializable (Serializable)

import Control.Monad (when, void)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException(..))
import Data.Binary (Binary, encode)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Maybe (catMaybes, maybeToList)
import Data.Monoid ((<>))
import Data.ByteString (ByteString)
import Data.List (delete, nub, (\\))
import Data.Typeable (Typeable)
import Data.Word (Word64)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

data NodeAgentConf = NodeAgentConf {
    softTimeout :: Defaultable Int
  , timeout :: Defaultable Int
} deriving (Eq, Typeable, Generic)

instance Binary (Defaultable Int)
instance Hashable (Defaultable Int)
instance Binary NodeAgentConf
instance Hashable NodeAgentConf

configSchema :: Schema NodeAgentConf
configSchema = let
    st = defaultableShow 5000000 . intOption $ long "softTimeout"
                   <> summary "Soft timeout for event propogation."
                   <> metavar "TIMEOUT"
                   <> argSummary "(Milliseconds)"
    t  = defaultableShow 10000000 . intOption $ long "timeout"
                   <> summary "Hard timeout for event propogation."
                   <> detail "This timeout needs to be lower than the promulgate timeout."
                   <> metavar "TIMEOUT"
                   <> argSummary "(Milliseconds)"
  in NodeAgentConf <$$> one st <**> one t

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

naSerializableDict :: SerializableDict NodeAgentConf
naSerializableDict = SerializableDict

naConfigDict :: Some ConfigDict
naConfigDict = mkConfigDict (undefined :: NodeAgentConf)

--TODO Can we auto-gen this whole section?
resourceDictServiceNA,
  resourceDictConfigItemNA :: Some ResourceDict
resourceDictServiceNA = mkResourceDict (undefined :: Service NodeAgentConf)
resourceDictConfigItemNA =
  mkResourceDict (undefined :: NodeAgentConf)

relationDictHasNodeServiceNA,
  relationDictWantsServiceNAConfigItemNA,
  relationDictHasServiceNAConfigItemNA :: Some RelationDict
relationDictHasNodeServiceNA = mkRelationDict (
  undefined :: (Runs, Node, Service NodeAgentConf))
relationDictWantsServiceNAConfigItemNA = mkRelationDict (
  undefined :: (WantsConf, Service NodeAgentConf, NodeAgentConf))
relationDictHasServiceNAConfigItemNA = mkRelationDict (
  undefined :: (HasConf, Service NodeAgentConf, NodeAgentConf))

remotable
  [ 'naConfigDict
  , 'naSerializableDict
  , 'resourceDictServiceNA
  , 'resourceDictConfigItemNA
  , 'relationDictHasNodeServiceNA
  , 'relationDictHasServiceNAConfigItemNA
  , 'relationDictWantsServiceNAConfigItemNA
  ]

instance Resource (Service NodeAgentConf) where
  resourceDict _ = $(mkStatic 'resourceDictServiceNA)

instance Resource NodeAgentConf where
  resourceDict _ = $(mkStatic 'resourceDictConfigItemNA)

instance Relation Runs Node (Service NodeAgentConf) where
  relationDict _ = $(mkStatic 'relationDictHasNodeServiceNA)

instance Relation HasConf (Service NodeAgentConf) NodeAgentConf where
  relationDict _ = $(mkStatic 'relationDictHasServiceNAConfigItemNA)

instance Relation WantsConf (Service NodeAgentConf) NodeAgentConf where
  relationDict _ = $(mkStatic 'relationDictWantsServiceNAConfigItemNA)

--------------------------------------------------------------------------------
-- Other stuff                                                                --
--------------------------------------------------------------------------------

instance Configuration NodeAgentConf where
  schema = configSchema
  sDict = $(mkStatic 'naSerializableDict)

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
    -- Yes I would like to know that too...

    -- | Hack to reify the serializable dictionary for Service
    sdictServiceInfo :: SerializableDict a
                     -> SerializableDict (String, Closure (a -> Process ()))
    sdictServiceInfo SerializableDict = SerializableDict

    -- | Wrap a service with means to register itself on a node and to handle
    --   service exit.
    serviceWrapper :: SerializableDict a
                   -> (String, Closure (a -> Process ()))
                      -- ^ Service name, closed process (only used in a message)
                   -> (a -> Process ())
                      -- ^ Service process to wrap (this one is actually used.)
                   -> (a -> Process ())
    serviceWrapper SerializableDict (name,_) p = \a -> do
        self <- getSelfPid
        either
            (\(ProcessRegistrationException _) -> return ())
            (const (go a))
          =<< try (register name self)
      where
        generalExpiate desc = do
          mbpid <- whereis nodeAgentLabel
          case mbpid of
             Nothing -> error "NodeAgent is not registered."
             Just na -> expiate $ ServiceUncaughtException (Node na) name desc
        myCatches n handler =
           (n >> handler (generalExpiate "Service died without exception")) `catches`
             [ Handler $ \(ExpireException (ExpireReason why)) -> handler $ expiate why,
               Handler $ \(SomeException e) -> handler $ generalExpiate $ show e ]
        go a = myCatches (p a) $ \res -> do
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
    service :: SerializableDict a
            -> Static (Some ConfigDict)
            -> Static (SerializableDict a)
            -> String -- ^ Service name
            -> Closure (a -> Process ())
            -> Service a
    service SerializableDict confDict dict name p =
        Service name (
            $(mkStatic 'serviceWrapper) `staticApply`
            dict `closureApplyStatic`
            closure (staticDecode sdict) (encode (name,p)) `closureApply`
            p
          ) confDict
      where
        sdict = $(mkStatic 'sdictServiceInfo) `staticApply` dict

    nodeAgentConfSDict :: SerializableDict NodeAgentConf
    nodeAgentConfSDict = SerializableDict

    -- | The master node agent process.
    nodeAgent :: Service NodeAgentConf
    nodeAgent = service
                  nodeAgentConfSDict
                  $(mkStatic 'naConfigDict)
                  $(mkStatic 'nodeAgentConfSDict)
                  nodeAgentLabel
                  $(mkStaticClosure 'nodeAgentProcess)

    nodeAgentProcess :: NodeAgentConf -> Process ()
    nodeAgentProcess conf = go $ NAState 0 [] Nothing
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
                      preferNodes = nub $
                        maybeToList (nasPreferredReplica nas) ++
                        take 1 (nasReplicas nas)
                      nodes = nasReplicas nas \\ preferNodes

                    -- Send the event to some replica.
                    result <- callLocal $
                      ncallRemoteAnyPreferTimeout (fromDefault . softTimeout $ conf)
                                                  (fromDefault . timeout $ conf)
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
