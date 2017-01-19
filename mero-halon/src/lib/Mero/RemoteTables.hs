-- |
-- Module    : Mero.RemoteTables
-- Copyright : (C) 2013 Xyratex Technology Limited.
--                 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of 'RemoteTable's used for mero functionality.
module Mero.RemoteTables (meroRemoteTable) where

import HA.Resources.Castor(__remoteTable)
import HA.Resources.RC(__remoteTable)
import HA.Resources.Mero(__remoteTable)
import HA.Resources.Mero.Note ( __remoteTable )
import HA.Services.Mero ( __remoteTable, __remoteTableDecl )
import HA.Services.Mero.RC (__remoteTable)
import System.Posix.SysInfo ( __remoteTable )
import HA.Services.Ekg ( __remoteTable, __remoteTableDecl )
import HA.Services.DecisionLog ( __remoteTable, __remoteTableDecl )
import HA.Services.Frontier ( __remoteTable, __remoteTableDecl )
import HA.Services.SSPL ( __remoteTable, __remoteTableDecl )
import HA.Services.SSPLHL ( __remoteTable, __remoteTableDecl )
import HA.Stats ( __remoteTable )
import HA.RecoveryCoordinator.Definitions ( __remoteTable )

import Control.Distributed.Process (RemoteTable)

-- | Remote tables used for mero.
meroRemoteTable :: RemoteTable -> RemoteTable
meroRemoteTable next =
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
