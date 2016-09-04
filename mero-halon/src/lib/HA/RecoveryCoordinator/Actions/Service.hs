-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Actions.Service
  ( -- * Querying services
    lookupInfoMsg
  , lookupConfig
  , findRegisteredOn
  , has
    -- * Registering services in the graph
  , declare
  , register
  , unregister
  , unregisterIfStopping
  , markStopping
    -- * Manupulating running services
  , Service.serviceInfoMsg
  , start
  , stop
  , requestStatusAsync
  ) where

import HA.Encode
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Events.Service
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.RC
import           HA.Service
  ( Configuration
  , Supports(..)
  , Service(..)
  , ServiceInfo(..)
  , ServiceInfoMsg
  , HasServiceInfoMsg
  )
import qualified HA.Service as Service

import Control.Category ((>>>))
import Control.Monad (join)
import Control.Distributed.Process
  ( Process
  , WhereIsReply(..)
  , expectTimeout
  , getSelfPid
  , spawnLocal
  , link
  , whereisRemoteAsync
  )
import Data.Traversable (for)
import Data.Typeable (cast)
import Data.Functor (void)
import Data.Maybe (listToMaybe)

import Network.CEP hiding (get, put, start, stop)

-- | Find all services on the node that are not marked as disconnecting
-- (i.e. node marked as 'Stopping').
findRegisteredOn :: Node -> PhaseM LoopState l [ServiceInfoMsg]
findRegisteredOn node = go <$> getLocalGraph
  where
    go rg = [ info
            | info <- G.connectedTo node Has rg
            , not $ G.isConnected node Stopping (info :: ServiceInfoMsg) rg
            ]

----------------------------------------------------------
-- Registering services in the graph                    --
----------------------------------------------------------

-- | Register that cluster supports given service.
declare  :: Configuration a
         => Service a
         -> PhaseM LoopState l ()
declare svc = modifyGraph $ G.newResource svc >>> G.connectUnique Cluster Supports svc

-- | Register service on a given node. After this halon will know that it needs
-- to send information to regular monitor services.
register :: Configuration a
         => Node
         -> Service a
         -> a
         -> PhaseM LoopState l ()
register node svc conf =
  modifyGraph $ snd . Service.registerServiceOnNode svc info node
  where info = encodeP (ServiceInfo svc conf)

-- | Unregister service on the given node.
unregister :: HasServiceInfoMsg si
           => Node
           -> si
           -> PhaseM LoopState l ()
unregister node info =
  modifyGraph $ G.disconnect node Has msg
            >>> G.disconnect node Stopping msg
  where
    msg = Service.serviceInfoMsg info

-- | Get encoded 'ServiceInfo' for service located on 'Node'.
lookupInfoMsg :: Configuration a
              => Node  -- ^ Node of interest.
              -> Service a -- ^ Service of interest.
              -> PhaseM LoopState l (Maybe ServiceInfoMsg)
lookupInfoMsg node svc =
  listToMaybe . Service.lookupServiceInfo node svc <$> getLocalGraph

-- | Lookup config of the Service that is started on the 'Node'.
lookupConfig :: Configuration a
             => Node  -- ^ Node of interest.
             -> Service a -- ^ Service of interest.
             -> PhaseM LoopState l (Maybe a)
lookupConfig node svc = do
   mmsg <- lookupInfoMsg node svc
   join <$> (for mmsg $ \msg -> do
     ServiceInfo _ c <- decodeMsg msg
     return (cast c))

-- | Start service on the node.
--
-- This call does not modify RG data.
start :: HasServiceInfoMsg si
      => Node -- ^ Remote node
      -> si -- ^ Config of the new service
      -> PhaseM LoopState l ()
start node info = liftProcess $ do
  self <- getSelfPid
  void $ spawnLocal $ do
    link self
    void $ Service.startRemoteService node (Service.serviceInfoMsg info)

-- | Stop service on the node.
--
-- This call does not modify RG data.
stop :: Configuration a
     => Node      -- ^ Remote node
     -> Service a -- ^ Config of the service to stop
     -> PhaseM LoopState l ()
stop node svc = liftProcess $ do
  self <- getSelfPid
  void $ spawnLocal $ do
    link self
    Service.stopRemoteService node svc

-- | Asynchronously request status of the halon service.
-- Status reply is processed in background thread.
--
requestStatusAsync :: Configuration a
                   => Node -- ^ Node where service is running.
                   -> Service a -- ^ Service of interest.
                   -> (ServiceStatusResponseMsg -> Process ()) -- ^ What to do with status
                   -> Process () -- ^ How to cleanup enviroment after work is done. We could
                                 -- mark message as processed here.
                   -> PhaseM LoopState l ()
requestStatusAsync node@(Node nid) srv onComplete finalize = do
  minfo <- lookupInfoMsg node srv
  liftProcess $ do
    self <- getSelfPid
    void $ spawnLocal $ do
      link self
      whereisRemoteAsync nid (Service.serviceLabel srv)
      mpid <- ((\(WhereIsReply _ p) -> p)  =<<) <$> expectTimeout 1000000 -- XXX: do better?
      case (minfo, mpid) of
        (Nothing, Nothing) ->
          onComplete $ encodeP $ SrvStatNotRunning
        (Nothing, Just pid) ->
          onComplete $ encodeP $ SrvStatStillRunning pid
        (Just info, Nothing) -> do
          ServiceInfo srv1 a <- decodeP info
          onComplete $ encodeP $ SrvStatFailed (Service.configDict srv1) a
        (Just info, Just pid) -> do
          ServiceInfo srv1 a <- decodeP info
          onComplete $ encodeP $ SrvStatRunning (Service.configDict srv1) pid a
      finalize

-- | Mark service as stopping
markStopping :: HasServiceInfoMsg s => Node -> s -> PhaseM LoopState l ()
markStopping node si =
  modifyGraph $ G.connect node Stopping (Service.serviceInfoMsg si) -- XXX: check "Has" relation

-- | Unregister service, but only if it's currently stopping.
unregisterIfStopping :: HasServiceInfoMsg si => Node -> si -> PhaseM LoopState l ()
unregisterIfStopping node info = do
  isStopping <- G.isConnected node Stopping msg <$> getLocalGraph
  if isStopping
  then modifyGraph $ G.disconnect node Has msg
  else return ()
  where msg = Service.serviceInfoMsg info

-- | Check if instance of service is registered on the node.
has :: HasServiceInfoMsg si => Node -> si -> PhaseM LoopState l Bool
has node info = G.isConnected node Has (Service.serviceInfoMsg info) <$> getLocalGraph
