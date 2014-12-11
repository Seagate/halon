-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}
module HA.Network.RemoteTables (haRemoteTable) where

import HA.ResourceGraph ( __remoteTable )
import HA.Resources ( __remoteTable )
import HA.NodeAgent ( __remoteTable, __remoteTableDecl )
import HA.Services.Dummy ( __remoteTable, __remoteTableDecl )
import HA.Services.Empty ( __remoteTable )
import HA.Service ( __remoteTable )
import HA.Services.OCF ( __remoteTableDecl )
import HA.RecoverySupervisor ( __remoteTable )
import HA.EventQueue ( __remoteTable )
import HA.Multimap.Process ( __remoteTable )
import HA.Replicator.Log (__remoteTable, __remoteTableDecl)

import Control.Distributed.Log ( __remoteTable, __remoteTableDecl )
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
   HA.ResourceGraph.__remoteTable $
   HA.Resources.__remoteTable $
   HA.NodeAgent.__remoteTable $
   HA.NodeAgent.__remoteTableDecl $
   HA.Services.Dummy.__remoteTable $
   HA.Services.Dummy.__remoteTableDecl $
   HA.Services.Empty.__remoteTable $
   HA.Service.__remoteTable $
   HA.Services.OCF.__remoteTableDecl $
   HA.RecoverySupervisor.__remoteTable $
   HA.EventQueue.__remoteTable $
   HA.Multimap.Process.__remoteTable $
   HA.Replicator.Log.__remoteTable $
   HA.Replicator.Log.__remoteTableDecl $
   Control.Distributed.Commands.Process.__remoteTable $
   Control.Distributed.Log.__remoteTable $
   Control.Distributed.Log.__remoteTableDecl $
   Control.Distributed.Log.Policy.__remoteTable $
   Control.Distributed.State.__remoteTable $
   Control.Distributed.Process.Consensus.__remoteTable $
   Control.Distributed.Process.Consensus.BasicPaxos.__remoteTable $
   next
