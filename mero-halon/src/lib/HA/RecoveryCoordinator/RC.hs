{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC
  ( subscribeTo
  , unsubscribeFrom
  ) where

import HA.EventQueue.Producer
  ( promulgate
  , promulgateWait
  )
import HA.RecoveryCoordinator.RC.Events

import Control.Distributed.Process
  ( Process
  , getSelfPid
  , receiveWait
  , matchIf
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
