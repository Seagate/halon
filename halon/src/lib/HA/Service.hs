-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module HA.Service
  (
    -- * Types
    Configuration
    -- ** Service type
    -- XXX: documentation about service in general
  , Service(..)
  , ServiceState
  , ServiceFunctions(..)
  , NextStep(..)
  , schema
  , sDict
  , spDict
  , serviceLabel
    -- ** Service info
  , ServiceInfo(..)
  , ServiceInfoMsg
  , HasServiceInfoMsg
  , serviceInfoMsg
    -- ** Configuration dictionaries
  , SomeConfigurationDict(..)
  , someConfigDict
    -- * Functions
    -- ** Service
    -- ** Graph manipulation
    -- $rg-structure
  , Supports(..)
  , Runs(..)
  , registerServiceOnNode
  , unregisterServicesOnNode
  , lookupServiceInfo
  , findRunningServiceOn
   -- * Messages
  , startRemoteService
  , stopRemoteService
   -- * Events
  , ServiceStarted(..)
  , ServiceFailed(..)
  , ServiceExit(..)
  , ServiceUncaughtException(..)
  , ServiceCouldNotStart(..)
  , ServiceStopNotRunning(..)
  , ExitReason(..)
   -- * CH Paraphenalia
  , HA.Service.Internal.__remoteTable
  , HA.Service.Internal.__resourcesTable
  , someConfigDict__static
  , HasInterface(..)
) where

import Control.Distributed.Process hiding (try)
import Control.Distributed.Process.Closure
import Control.Monad

import Data.Bifunctor (first, second)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import HA.Encode
import HA.EventQueue.Producer
import HA.Service.Internal
import HA.ResourceGraph
import HA.Resources
import HA.SafeCopy

--------------------------------------------------------------------------------
-- Service messages                                                           --
--------------------------------------------------------------------------------

-- | A notification of a failure to start a service.
data ServiceCouldNotStart = ServiceCouldNotStart Node ServiceInfoMsg
  deriving (Typeable, Generic)
deriveSafeCopy 0 'base ''ServiceCouldNotStart

-- | A notification of a successful service start.
data ServiceStarted = ServiceStarted Node ServiceInfoMsg ProcessId
  deriving (Typeable, Generic)
deriveSafeCopy 0 'base ''ServiceStarted

-- | Add a entry that service with some config should be running on the
-- any given node. This functions disconnects all the services of the given
-- type and returnes them as a first tuple.
registerServiceOnNode :: forall a. Configuration a
                      => Service a
                      -> ServiceInfoMsg
                      -> Node
                      -> Graph
                      -> ([ServiceInfoMsg], Graph)
registerServiceOnNode srv msg node = first (filter (/= msg)) .
  second (connect node Has msg) . unregisterServicesOnNode srv node

-- | Disconnect all services of a given type from the node. When service is
-- registered all previous other instances of the same service on the node
-- should be removed. This happens because there can be only one service on
-- the node.
--
-- Returns all 'ServiceInfoMsg' that were removed.
unregisterServicesOnNode :: Configuration a => Service a -> Node -> Graph -> ([ServiceInfoMsg], Graph)
unregisterServicesOnNode service node rg = (configs, foldr (disconnect node Has) rg configs)
  where configs = lookupServiceInfo node service rg

-- | Find and decode config for the given service attached to node.
lookupServiceInfo :: Node -> Service a -> Graph -> [ServiceInfoMsg]
lookupServiceInfo node srv = filter (\i -> configDict srv == getServiceInfoDict i)
                           . connectedTo node Has

-- | Given a set of 'Node's and a 'Service', produce a set of nodes on
-- which the service is known to be running.
findRunningServiceOn :: [Node] -> Service a -> Graph -> [Node]
findRunningServiceOn ns svc rg =
  filter (\n -> not . Prelude.null $ lookupServiceInfo n svc rg) ns

-- | Synchronously start service on the remote node.
--
-- N.B. This call is does not use helper thread, so if postphoned messages
-- may arrive into the thread where it's called.
startRemoteService :: HasServiceInfoMsg si
                   => Node   -- ^ Node to start service on
                   -> si -- ^ Service
                   -> Process (Maybe ProcessId)
startRemoteService node@(Node nid) (serviceInfoMsg -> msg) = do
  mref <- monitorNode nid
  (sp, rp) <- newChan
  void $ spawnAsync nid $ $(mkClosure 'remoteStartService) (sp, msg)
  receiveWait
    [ matchIf (\(NodeMonitorNotification ref _ _) -> ref == mref)
        $ \_ -> do promulgateWait $ ServiceCouldNotStart node msg
                   return Nothing
    , matchChan rp $ \pid -> do
        promulgateWait $ ServiceStarted node msg pid
        return (Just pid)
    ]
{-# SPECIALIZE startRemoteService :: Node -> ServiceInfoMsg -> Process (Maybe ProcessId) #-}
{-# SPECIALIZE startRemoteService :: Node -> ServiceInfo -> Process (Maybe ProcessId) #-}

-- | Synchronously stop service on the remote node.
stopRemoteService :: forall a . Configuration a
                  => Node   -- ^ Node to stop service on
                  -> Service a
                  -> Process ()
stopRemoteService node@(Node nid) svc = do
  mref <- monitorNode nid
  let label = serviceLabel svc
  (sp, rp) <- newChan
  void $ spawnAsync nid $ $(mkClosure 'remoteStopService) (sp, label)
  receiveWait
    [ matchIf (\(NodeMonitorNotification ref _ _) -> ref == mref)
        $ \_ -> return ()
    , matchChan rp $ \b -> unless b $ do
        promulgateWait (ServiceStopNotRunning node label)
    ]

-- XXX: use ADT instead?
-- | In many cases it's irrelevant what user will provide to the method,
-- either ServiceInfoMsg or ServiceInfo, because we always can convert latter to
-- former. However this may simplify API much if we will run conversion on the
-- lowest level. Operationally this will be the same as providing to functions.
class HasServiceInfoMsg a where
  -- | Create a 'ServiceInfoMsg'.
  serviceInfoMsg :: a -> ServiceInfoMsg
instance HasServiceInfoMsg ServiceInfoMsg where
  serviceInfoMsg = id
  {-# INLINE serviceInfoMsg #-}
instance HasServiceInfoMsg ServiceInfo where
  serviceInfoMsg = encodeP
  {-# INLINE serviceInfoMsg #-}

-- $rg-structure
--
-- @
--                     +---------+
--                     | Cluster |
--                     +---------+
--            Has        |     |    Supports
--          +------------+     +----------------------+
--          |                                         |
--          v                                         v
--      +--------+  Has   +----------------+    +-------------+
--      | Node   |------->|  ServiceInfo   |    |  Service n  |
--      +--------+        +----------------+    +-------------+
-- @
--
-- In order to generate all structure automatically use "HA.Service.TH" module.
