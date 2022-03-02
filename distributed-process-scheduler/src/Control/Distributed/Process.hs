-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This module exports wrappers of the functions exported by
-- "Control.Distributed.Process" in the distributed-process package.
--
-- The wrappers perform like the functions from distributed-process when the
-- scheduler is not enabled. When the scheduler is enabled, they communicate
-- with the scheduler to coordinate execution of the multiple processes in the
-- application.
--
-- Please refer to distributed-process for the documentation of each function.
--
-- Unwrapped functions are reexported in
-- "Control.Distributed.Process.Scheduler.Raw".

{-# LANGUAGE PackageImports #-}
{-# LANGUAGE MonoLocalBinds #-}

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
  , matchMessageIf
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
  ( ifSchedulerIsEnabled
  , Match
  , match
  , matchIf
  , matchChan
  , matchSTM
  , matchAny
  , matchMessageIf
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
  , matchMessageIf
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

import qualified Control.Monad.Catch as C


usend :: Serializable a => ProcessId -> a -> Process ()
usend = ifSchedulerIsEnabled Internal.usend DP.usend

say :: String -> Process ()
say = ifSchedulerIsEnabled Internal.say DP.say

nsend :: Serializable a => String -> a -> Process ()
nsend = ifSchedulerIsEnabled Internal.nsend DP.nsend

nsendRemote :: Serializable a => NodeId -> String -> a -> Process ()
nsendRemote = ifSchedulerIsEnabled Internal.nsendRemote DP.nsendRemote

sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan = ifSchedulerIsEnabled Internal.sendChan DP.sendChan

uforward :: Message -> ProcessId -> Process ()
uforward = ifSchedulerIsEnabled Internal.uforward DP.uforward

receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan = ifSchedulerIsEnabled Internal.receiveChan DP.receiveChan

receiveChanTimeout :: Serializable a
                   => Int -> ReceivePort a -> Process (Maybe a)
receiveChanTimeout t rPort = receiveTimeout t [ matchChan rPort return ]

monitor :: ProcessId -> Process DP.MonitorRef
monitor = ifSchedulerIsEnabled Internal.monitor DP.monitor

monitorNode :: NodeId -> Process DP.MonitorRef
monitorNode = ifSchedulerIsEnabled Internal.monitorNode DP.monitorNode

unmonitor :: DP.MonitorRef -> Process ()
unmonitor = ifSchedulerIsEnabled Internal.unmonitor DP.unmonitor

withMonitor :: ProcessId -> Process a -> Process a
withMonitor pid code = C.bracket (monitor pid) unmonitor (\_ -> code)

link :: ProcessId -> Process ()
link = ifSchedulerIsEnabled Internal.link DP.link

unlink :: ProcessId -> Process ()
unlink = ifSchedulerIsEnabled Internal.unlink DP.unlink

linkNode :: NodeId -> Process ()
linkNode = ifSchedulerIsEnabled Internal.linkNode DP.linkNode

exit :: Serializable a => ProcessId -> a -> Process ()
exit = ifSchedulerIsEnabled Internal.exit DP.exit

kill :: ProcessId -> String -> Process ()
kill = ifSchedulerIsEnabled Internal.kill DP.kill

spawnLocal :: Process () -> Process ProcessId
spawnLocal = ifSchedulerIsEnabled Internal.spawnLocal DP.spawnLocal

spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn = ifSchedulerIsEnabled Internal.spawn DP.spawn

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

callLocal :: Process a -> Process a
callLocal = ifSchedulerIsEnabled Internal.callLocal DP.callLocal

whereis :: String -> Process (Maybe ProcessId)
whereis = ifSchedulerIsEnabled Internal.whereis DP.whereis

register :: String -> ProcessId -> Process ()
register = ifSchedulerIsEnabled Internal.register DP.register

reregister :: String -> ProcessId -> Process ()
reregister = ifSchedulerIsEnabled Internal.reregister DP.reregister

whereisRemoteAsync :: NodeId -> String -> Process ()
whereisRemoteAsync = ifSchedulerIsEnabled Internal.whereisRemoteAsync
                                          DP.whereisRemoteAsync

registerRemoteAsync :: NodeId -> String -> ProcessId -> Process ()
registerRemoteAsync = ifSchedulerIsEnabled Internal.registerRemoteAsync
                                           DP.registerRemoteAsync

expectTimeout :: Serializable a => Int -> Process (Maybe a)
expectTimeout t = receiveTimeout t [ match return ]
