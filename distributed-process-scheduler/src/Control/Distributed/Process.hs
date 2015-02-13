-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process
  ( Match
  , send
  , usend
  , sendChan
  , match
  , matchIf
  , matchChan
  , matchSTM
  , expect
  , expectTimeout
  , receiveWait
  , receiveChan
  , spawnLocal
  , spawn
  , module DPEtc
  )  where

import Control.Distributed.Process.Scheduler.Internal
  ( Match
  , match
  , matchIf
  , matchChan
  , matchSTM
  , expect
  , receiveWait )
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import qualified "distributed-process" Control.Distributed.Process as DP
import "distributed-process" Control.Distributed.Process as DPEtc
    hiding
  ( Match
  , send
  , usend
  , sendChan
  , match
  , matchIf
  , matchChan
  , matchSTM
  , expect
  , expectTimeout
  , receiveWait
  , receiveChan
  , spawnLocal
  , spawn )
import Control.Distributed.Process.Serializable ( Serializable )

-- These functions are marked NOINLINE, because this way the "if"
-- statement only has to be evaluated once and not at every call site.
-- After the first evaluation, these top-level functions are simply a
-- jump to the appropriate function.

{-# NOINLINE send #-}
send :: Serializable a => ProcessId -> a -> Process ()
send = if Internal.schedulerIsEnabled
       then Internal.send
       else DP.send

{-# NOINLINE usend #-}
usend :: Serializable a => ProcessId -> a -> Process ()
usend = if Internal.schedulerIsEnabled
       then Internal.usend
       else DP.usend

{-# NOINLINE sendChan #-}
sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan = if Internal.schedulerIsEnabled
           then Internal.sendChan
           else DP.sendChan

{-# NOINLINE receiveChan #-}
receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan = if Internal.schedulerIsEnabled
              then Internal.receiveChan
              else DP.receiveChan

{-# NOINLINE spawnLocal #-}
spawnLocal :: Process () -> Process ProcessId
spawnLocal = if Internal.schedulerIsEnabled
             then Internal.spawnLocal
             else DP.spawnLocal

{-# NOINLINE spawn #-}
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn = if Internal.schedulerIsEnabled
        then Internal.spawn
        else DP.spawn

{-# NOINLINE expectTimeout #-}
expectTimeout :: Serializable a => Int -> Process (Maybe a)
expectTimeout = if Internal.schedulerIsEnabled
        then fmap Just . const Internal.expect
        else DP.expectTimeout
