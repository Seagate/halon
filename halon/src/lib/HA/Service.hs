-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -Werror #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module HA.Service
  (
    -- * Types
    Configuration
    -- ** Service type
    -- XXX: documentation about service in general
  , Service(..)
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
   -- * Messages
  , startRemoteService
  , stopRemoteService
   -- * Events
  , ServiceStarted(..)
  , ServiceFailed(..)
  , ServiceExit(..)
  , ServiceUncaughtException(..)
  , ServiceCouldNotStart(..)
  , ExitReason(..)
   -- * CH Paraphenalia
  , HA.Service.Internal.__remoteTable
  , someConfigDict__static
) where

import Control.Distributed.Process hiding (try)
import Control.Distributed.Process.Closure
import Control.Monad

import Data.Bifunctor (first, second)
import Data.Binary as Binary
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import HA.Encode
import HA.EventQueue.Producer
import HA.Service.Internal
import HA.ResourceGraph
import HA.Resources

--------------------------------------------------------------------------------
-- Service messages                                                           --
--------------------------------------------------------------------------------

-- | A notification of a failure to start a service.
data ServiceCouldNotStart = ServiceCouldNotStart Node ServiceInfoMsg
  deriving (Typeable, Generic)

instance Binary ServiceCouldNotStart

-- | A notification of a successful service start.
data ServiceStarted = ServiceStarted Node ServiceInfoMsg ProcessId
  deriving (Typeable, Generic)

instance Binary ServiceStarted

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

-- | Synchronously start service on the remote node.
--
-- N.B. This call is does not use helper thread, so if postphoned messages
-- may arrive into the thread where it's called.
startRemoteService :: HasServiceInfoMsg si
                   => Node   -- ^ Node to start service on
                   -> si -- ^ Service
                   -> Process (Maybe ProcessId)
startRemoteService node@(Node nid) (serviceInfoMsg -> msg) = do
  self <- getSelfPid
  mref <- monitorNode nid
  void $ spawnAsync nid $ $(mkClosure 'remoteStartService) (self, msg)
  receiveWait
    [ matchIf (\(NodeMonitorNotification ref _ _) -> ref == mref)
        $ \_ -> do promulgateWait $ ServiceCouldNotStart node msg
                   return Nothing
    , match $ \pid -> do
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
stopRemoteService (Node nid) svc = do
  self <- getSelfPid
  mref <- monitorNode nid
  let label = serviceLabel svc
  void $ spawnAsync nid $ $(mkClosure 'remoteStopService) (self, label)
  receiveWait
    [ matchIf (\(NodeMonitorNotification ref _ _) -> ref == mref)
        $ \_ -> return ()
    , match $ \() -> return ()
    ]

-- XXX: use ADT instead?
-- | In many cases it's irrelevant what user will provide to the method,
-- either ServiceInfoMsg or ServiceInfo, because we always can convert latter to
-- former. However this may simplify API much if we will run conversion on the
-- lowest level. Operationally this will be the same as providing to functions.
class HasServiceInfoMsg a where
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
