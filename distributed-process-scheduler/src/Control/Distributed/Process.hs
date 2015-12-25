-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process
  ( Match
  , usend
  , say
  , nsend
  , nsendRemote
  , sendChan
  , uforward
  , match
  , matchIf
  , matchChan
  , matchSTM
  , matchAny
  , expect
  , expectTimeout
  , receiveWait
  , receiveTimeout
  , receiveChan
  , receiveChanTimeout
  , monitor
  , unmonitor
  , withMonitor
  , monitorNode
  , link
  , linkNode
  , unlink
  , exit
  , kill
  , spawnLocal
  , spawn
  , spawnAsync
  , DidSpawn(..)
  , spawnChannelLocal
  , spawnMonitor
  , callLocal
  , whereis
  , register
  , reregister
  , unregister
  , whereisRemoteAsync
  , registerRemoteAsync
--  , module DPEtc
  , Process
  , ProcessId(..)
  , MonitorRef
  , NodeId(..)
  , SendPort
  , ReceivePort
  , Static
  , Closure
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , ProcessRegistrationException(..)
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , RegisterReply(..)
  , WhereIsReply(..)
  , RemoteTable
  , DiedReason(..)
  , unStatic
  , unClosure
  , closure
  , handleMessage
  , handleMessageIf
  , liftIO
  , finally
  , bracket
  , bracket_
  , die
  , getSelfPid
  , getSelfNode
  , newChan
  , catch
  , catches
  , Handler(..)
  , catchExit
  , catchesExit
  , mask
  , mask_
  , try
  , onException
  , Message
  , wrapMessage
  , unwrapMessage
  )  where

import Control.Distributed.Process.Scheduler.Internal
  ( Match
  , match
  , matchIf
  , matchChan
  , matchSTM
  , matchAny
  , expect
  , receiveWait
  , receiveTimeout
  )
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import qualified "distributed-process" Control.Distributed.Process as DP
import "distributed-process" Control.Distributed.Process as DPEtc
    hiding
  ( Match
  , usend
  , say
  , nsend
  , nsendRemote
  , sendChan
  , uforward
  , match
  , matchIf
  , matchChan
  , matchSTM
  , matchAny
  , expect
  , expectTimeout
  , receiveTimeout
  , receiveWait
  , receiveChan
  , receiveChanTimeout
  , monitor
  , unmonitor
  , withMonitor
  , monitorNode
  , link
  , linkNode
  , unlink
  , exit
  , kill
  , spawnLocal
  , spawn
  , spawnAsync
  , spawnChannelLocal
  , spawnMonitor
  , callLocal
  , whereis
  , register
  , reregister
  , whereisRemoteAsync
  , registerRemoteAsync
  )
import Control.Distributed.Process.Serializable ( Serializable )

ifSchedulerIsEnabled :: a -> a -> a
ifSchedulerIsEnabled a b
    | Internal.schedulerIsEnabled = a
    | otherwise                   = b

-- These functions are marked NOINLINE, because this way the "if"
-- statement only has to be evaluated once and not at every call site.
-- After the first evaluation, these top-level functions are simply a
-- jump to the appropriate function.

{-# NOINLINE usend #-}
usend :: Serializable a => ProcessId -> a -> Process ()
usend = ifSchedulerIsEnabled Internal.usend DP.usend

{-# NOINLINE say #-}
say :: String -> Process ()
say = ifSchedulerIsEnabled Internal.say DP.say

{-# NOINLINE nsend #-}
nsend :: Serializable a => String -> a -> Process ()
nsend = ifSchedulerIsEnabled Internal.nsend DP.nsend

{-# NOINLINE nsendRemote #-}
nsendRemote :: Serializable a => NodeId -> String -> a -> Process ()
nsendRemote = ifSchedulerIsEnabled Internal.nsendRemote DP.nsendRemote

{-# NOINLINE sendChan #-}
sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan = ifSchedulerIsEnabled Internal.sendChan DP.sendChan

{-# NOINLINE uforward #-}
uforward :: Message -> ProcessId -> Process ()
uforward = ifSchedulerIsEnabled Internal.uforward DP.uforward

{-# NOINLINE receiveChan #-}
receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan = ifSchedulerIsEnabled Internal.receiveChan DP.receiveChan

-- | Wait for a message on a typed channel for at least the given amount of
-- microseconds.
receiveChanTimeout :: Serializable a
                   => Int -> ReceivePort a -> Process (Maybe a)
receiveChanTimeout t rPort = receiveTimeout t [ matchChan rPort return ]

{-# NOINLINE monitor #-}
monitor :: ProcessId -> Process DP.MonitorRef
monitor = ifSchedulerIsEnabled Internal.monitor DP.monitor

{-# NOINLINE monitorNode #-}
monitorNode :: NodeId -> Process DP.MonitorRef
monitorNode = ifSchedulerIsEnabled Internal.monitorNode DP.monitorNode

{-# NOINLINE unmonitor #-}
unmonitor :: DP.MonitorRef -> Process ()
unmonitor = ifSchedulerIsEnabled Internal.unmonitor DP.unmonitor

withMonitor :: ProcessId -> Process a -> Process a
withMonitor pid code = bracket (monitor pid) unmonitor (\_ -> code)

{-# NOINLINE link #-}
link :: ProcessId -> Process ()
link = ifSchedulerIsEnabled Internal.link DP.link

{-# NOINLINE unlink #-}
unlink :: ProcessId -> Process ()
unlink = ifSchedulerIsEnabled Internal.unlink DP.unlink

{-# NOINLINE linkNode #-}
linkNode :: NodeId -> Process ()
linkNode = ifSchedulerIsEnabled Internal.linkNode DP.linkNode

{-# NOINLINE exit #-}
exit :: Serializable a => ProcessId -> a -> Process ()
exit = ifSchedulerIsEnabled Internal.exit DP.exit

{-# NOINLINE kill #-}
kill :: ProcessId -> String -> Process ()
kill = ifSchedulerIsEnabled Internal.kill DP.kill

{-# NOINLINE spawnLocal #-}
spawnLocal :: Process () -> Process ProcessId
spawnLocal = ifSchedulerIsEnabled Internal.spawnLocal DP.spawnLocal

{-# NOINLINE spawn #-}
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn = ifSchedulerIsEnabled Internal.spawn DP.spawn

{-# NOINLINE spawnAsync #-}
spawnAsync :: NodeId -> Closure (Process ()) -> Process DP.SpawnRef
spawnAsync = ifSchedulerIsEnabled Internal.spawnAsync DP.spawnAsync

spawnChannelLocal :: Serializable a
                  => (ReceivePort a -> Process ())
                  -> Process (SendPort a)
spawnChannelLocal = ifSchedulerIsEnabled Internal.spawnChannelLocal
                                         DP.spawnChannelLocal
spawnMonitor :: NodeId -> Closure (Process ())
             -> Process (ProcessId, DP.MonitorRef)
spawnMonitor = ifSchedulerIsEnabled Internal.spawnMonitor DP.spawnMonitor

{-# NOINLINE callLocal #-}
callLocal :: Process a -> Process a
callLocal = ifSchedulerIsEnabled Internal.callLocal DP.callLocal

{-# NOINLINE whereis #-}
whereis :: String -> Process (Maybe ProcessId)
whereis = ifSchedulerIsEnabled Internal.whereis DP.whereis

{-# NOINLINE register #-}
register :: String -> ProcessId -> Process ()
register = ifSchedulerIsEnabled Internal.register DP.register

{-# NOINLINE reregister #-}
reregister :: String -> ProcessId -> Process ()
reregister = ifSchedulerIsEnabled Internal.reregister DP.reregister

{-# NOINLINE whereisRemoteAsync #-}
whereisRemoteAsync :: NodeId -> String -> Process ()
whereisRemoteAsync = ifSchedulerIsEnabled Internal.whereisRemoteAsync
                                          DP.whereisRemoteAsync

{-# NOINLINE registerRemoteAsync #-}
registerRemoteAsync :: NodeId -> String -> ProcessId -> Process ()
registerRemoteAsync = ifSchedulerIsEnabled Internal.registerRemoteAsync
                                           DP.registerRemoteAsync

{-# NOINLINE expectTimeout #-}
expectTimeout :: Serializable a => Int -> Process (Maybe a)
expectTimeout t = receiveTimeout t [ match return ]
