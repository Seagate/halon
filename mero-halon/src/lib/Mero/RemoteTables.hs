-- |
-- Module    : Mero.RemoteTables
-- Copyright : (C) 2013 Xyratex Technology Limited.
--                 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of 'RemoteTable's used for mero functionality.
module Mero.RemoteTables (meroRemoteTable) where

import HA.Resources.Castor(__remoteTable, __resourcesTable)
import HA.Resources.RC(__remoteTable, __resourcesTable)
import HA.Resources.Mero(__remoteTable, __resourcesTable)
import HA.Resources.Mero.Note ( __remoteTable, __resourcesTable)
import HA.Services.Mero ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Services.Mero.RC (__remoteTable, __resourcesTable)
import System.Posix.SysInfo ( __remoteTable )
import HA.Services.Ekg ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Services.DecisionLog ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Services.Frontier ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Services.SSPL ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Services.SSPLHL ( __remoteTable, __remoteTableDecl, __resourcesTable )
import HA.Stats ( __remoteTable )
import HA.RecoveryCoordinator.Definitions ( __remoteTable )

import Control.Distributed.Process (RemoteTable)

-- | Remote tables used for mero.
meroRemoteTable :: RemoteTable -> RemoteTable
meroRemoteTable next =
   HA.Services.SSPLHL.__resourcesTable $
   HA.Services.SSPL.__resourcesTable $
   HA.Services.Frontier.__resourcesTable $
   HA.Services.DecisionLog.__resourcesTable $
   HA.Services.Ekg.__resourcesTable $
   HA.Services.Mero.RC.__resourcesTable $
   HA.Services.Mero.__resourcesTable $
   HA.Resources.Mero.Note.__resourcesTable $
   HA.Resources.Mero.__resourcesTable $
   HA.Resources.RC.__resourcesTable $
   HA.Resources.Castor.__resourcesTable $
   HA.Resources.Castor.__remoteTable $
   HA.Resources.RC.__remoteTable $
   HA.Resources.Mero.__remoteTable $
   HA.Resources.Mero.Note.__remoteTable $
   HA.Services.Mero.__remoteTableDecl $
   HA.Services.Mero.__remoteTable $
   HA.Services.Mero.RC.__remoteTable $
   System.Posix.SysInfo.__remoteTable $
   HA.Services.SSPL.__remoteTable $
   HA.Services.SSPL.__remoteTableDecl $
   HA.Services.SSPLHL.__remoteTable $
   HA.Services.SSPLHL.__remoteTableDecl $
   HA.Services.Frontier.__remoteTable $
   HA.Services.Frontier.__remoteTableDecl $
   HA.Services.Ekg.__remoteTable $
   HA.Services.Ekg.__remoteTableDecl $
   HA.Services.DecisionLog.__remoteTable $
   HA.Services.DecisionLog.__remoteTableDecl $
   HA.Stats.__remoteTable $
   HA.RecoveryCoordinator.Definitions.__remoteTable $
   next
