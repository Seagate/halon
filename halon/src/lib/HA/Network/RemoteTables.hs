-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}
module HA.Network.RemoteTables (haRemoteTable) where

import HA.NodeUp ( __remoteTable)
import HA.Logger ( __remoteTable)
import HA.ResourceGraph ( __remoteTable)
import HA.Resources ( __remoteTable, __resourcesTable )
import HA.Services.Dummy ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Services.Noisy ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Services.Ping ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Service ( __remoteTable, __resourcesTable )
import HA.Startup ( __remoteTable, __remoteTableDecl)
import HA.EventQueue.Process ( __remoteTable)
import HA.EQTracker.Process ( __remoteTable)
import HA.Multimap.Process ( __remoteTable)
import HA.Replicator.Log (__remoteTable, __remoteTableDecl)

import Control.Distributed.Log ( __remoteTable )
import Control.Distributed.Log.Policy ( __remoteTable )
import Control.Distributed.State ( __remoteTable )
import Control.Distributed.Commands.Process ( __remoteTable )
import Control.Distributed.Process
import Control.Distributed.Process.Consensus ( __remoteTable )
import Control.Distributed.Process.Consensus.BasicPaxos ( __remoteTable )

-- | This is the master remote table for the whole
-- library. All modules invoking remotable should
-- collect their remote tables here.
haRemoteTable :: RemoteTable -> RemoteTable
haRemoteTable next =
   HA.Service.__resourcesTable $
   HA.Services.Ping.__resourcesTable $
   HA.Services.Noisy.__resourcesTable $
   HA.Services.Dummy.__resourcesTable $
   HA.Resources.__resourcesTable $
   HA.NodeUp.__remoteTable $
   HA.Logger.__remoteTable $
   HA.ResourceGraph.__remoteTable $
   HA.Resources.__remoteTable $
   HA.Services.Dummy.__remoteTable $
   HA.Services.Dummy.__remoteTableDecl $
   HA.Services.Noisy.__remoteTable $
   HA.Services.Noisy.__remoteTableDecl $
   HA.Services.Ping.__remoteTable $
   HA.Services.Ping.__remoteTableDecl $
   HA.Service.__remoteTable $
   HA.Startup.__remoteTable $
   HA.Startup.__remoteTableDecl $
   HA.EventQueue.Process.__remoteTable $
   HA.EQTracker.Process.__remoteTable $
   HA.Multimap.Process.__remoteTable $
   HA.Replicator.Log.__remoteTable $
   HA.Replicator.Log.__remoteTableDecl $
   Control.Distributed.Commands.Process.__remoteTable $
   Control.Distributed.Log.__remoteTable $
   Control.Distributed.Log.Policy.__remoteTable $
   Control.Distributed.State.__remoteTable $
   Control.Distributed.Process.Consensus.__remoteTable $
   Control.Distributed.Process.Consensus.BasicPaxos.__remoteTable $
   next
