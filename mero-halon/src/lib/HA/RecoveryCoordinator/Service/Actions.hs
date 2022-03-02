-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
module HA.RecoveryCoordinator.Service.Actions
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
import HA.RecoveryCoordinator.RC.Actions.Core
import HA.RecoveryCoordinator.Service.Events
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.RC hiding (RC)
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
findRegisteredOn :: Node -> PhaseM RC l [ServiceInfoMsg]
findRegisteredOn node = go <$> getGraph
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
         -> PhaseM RC l ()
declare svc = modifyGraph $ G.connect Cluster Supports svc

-- | Register service on a given node. After this halon will know that it needs
-- to send information to regular monitor services.
register :: Configuration a
         => Node
         -> Service a
         -> a
         -> PhaseM RC l ()
register node svc conf =
  modifyGraph $ snd . Service.registerServiceOnNode svc info node
  where info = encodeP (ServiceInfo svc conf)

-- | Unregister service on the given node.
unregister :: HasServiceInfoMsg si
           => Node
           -> si
           -> PhaseM RC l ()
unregister node info =
  modifyGraph $ G.disconnect node Has msg
            >>> G.disconnect node Stopping msg
  where
    msg = Service.serviceInfoMsg info

-- | Get encoded 'ServiceInfo' for service located on 'Node'.
lookupInfoMsg :: Node  -- ^ Node of interest.
              -> Service a -- ^ Service of interest.
              -> PhaseM RC l (Maybe ServiceInfoMsg)
lookupInfoMsg node svc =
  listToMaybe . Service.lookupServiceInfo node svc <$> getGraph

-- | Lookup config of the Service that is started on the 'Node'.
lookupConfig :: Configuration a
             => Node  -- ^ Node of interest.
             -> Service a -- ^ Service of interest.
             -> PhaseM RC l (Maybe a)
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
      -> PhaseM RC l ()
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
     -> PhaseM RC l ()
stop node svc = liftProcess $ do
  self <- getSelfPid
  void $ spawnLocal $ do
    link self
    Service.stopRemoteService node svc

-- | Asynchronously request status of the halon service.
-- Status reply is processed in background thread.
--
requestStatusAsync :: Node -- ^ Node where service is running.
                   -> Service a -- ^ Service of interest.
                   -> (ServiceStatusResponseMsg -> Process ()) -- ^ What to do with status
                   -> Process () -- ^ How to cleanup enviroment after work is done. We could
                                 -- mark message as processed here.
                   -> PhaseM RC l ()
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
markStopping :: HasServiceInfoMsg s => Node -> s -> PhaseM RC l ()
markStopping node si =
  modifyGraph $ G.connect node Stopping (Service.serviceInfoMsg si) -- XXX: check "Has" relation

-- | Unregister service, but only if it's currently stopping.
unregisterIfStopping :: HasServiceInfoMsg si => Node -> si -> PhaseM RC l ()
unregisterIfStopping node info = do
  isStopping <- G.isConnected node Stopping msg <$> getGraph
  if isStopping
  then modifyGraph $ G.disconnect node Has msg
  else return ()
  where msg = Service.serviceInfoMsg info

-- | Check if instance of service is registered on the node.
has :: HasServiceInfoMsg si => Node -> si -> PhaseM RC l Bool
has node info = G.isConnected node Has (Service.serviceInfoMsg info) <$> getGraph
