{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
module HA.RecoveryCoordinator.RC.Subscription
  ( subscribeTo
  , unsubscribeFrom
  , subscribeOnTo
  , unsubscribeOnFrom
  ) where

import HA.EventQueue (promulgate, promulgateEQ, promulgateEQ_, promulgateWait)
import HA.RecoveryCoordinator.RC.Events

import Control.Distributed.Process
  ( Process
  , NodeId
  , ProcessMonitorNotification(..)
  , getSelfPid
  , receiveWait
  , matchIf
  , monitor
  )
import Control.Distributed.Process.Serializable
import Data.Proxy
import Data.Typeable

-- | Persistently subscibe to RC events. This means that subscription will
-- be kept alive even if RC is restarted. This method is asynchronous and
-- Process will block until reply from RC will be received. This means
-- that all notifications sent after this event may be handled.
subscribeTo :: forall a . Typeable a => Proxy a -> Process ()
subscribeTo _ = do
  let fp = fingerprint (undefined :: a)
      fpBs = encodeFingerprint fp
  self <- getSelfPid
  _ <- promulgate $ SubscribeToRequest self fpBs
  receiveWait
    [ matchIf (\(SubscribeToReply fp') -> fp' == fpBs) (const $ return ())]

-- | Unsubscribe from persistent subcription. This call will exit when
-- request will be persisten in the replicated state, but RC will not send
-- any acknowledgement. However it's guaranteed that RC will process
-- request at least once.
unsubscribeFrom :: forall a . Typeable a =>Proxy a -> Process ()
unsubscribeFrom _ = do
  let fp = fingerprint (undefined :: a)
      fpBs = encodeFingerprint fp
  self <- getSelfPid
  promulgateWait $ UnsubscribeFromRequest self fpBs

-- | 'subscribeTo' but pass nodes with event queues explicitly.
subscribeOnTo :: forall a . Typeable a => [NodeId] -> Proxy a -> Process ()
subscribeOnTo nids _ = do
  let fp = fingerprint (undefined :: a)
      fpBs = encodeFingerprint fp
  self <- getSelfPid
  promulgateEQ_ nids $ SubscribeToRequest self fpBs
  receiveWait
    [ matchIf (\(SubscribeToReply fp') -> fp' == fpBs) (const $ return ())]

-- | 'subscribeFrom' but pass nodes with event queues explicitly
unsubscribeOnFrom :: forall a . Typeable a => [NodeId] -> Proxy a -> Process ()
unsubscribeOnFrom nids _ = do
  let fp = fingerprint (undefined :: a)
      fpBs = encodeFingerprint fp
  self <- getSelfPid
  pid  <- promulgateEQ nids $ UnsubscribeFromRequest self fpBs
  mref <- monitor pid
  receiveWait [matchIf (\(ProcessMonitorNotification p _ _) -> p == mref)
                       (const $ return ())
              ]
