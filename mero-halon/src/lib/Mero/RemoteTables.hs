-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}
module Mero.RemoteTables (meroRemoteTable) where

import HA.Resources.Castor(__remoteTable)
#ifdef USE_MERO
import HA.Resources.Mero(__remoteTable)
import HA.Resources.Mero.Note ( __remoteTable )
import HA.Services.Mero ( __remoteTable, __remoteTableDecl )
#endif

import HA.Services.DecisionLog ( __remoteTable, __remoteTableDecl )
import HA.Services.Frontier ( __remoteTable, __remoteTableDecl )
import HA.Services.Monitor ( __remoteTable, __remoteTableDecl )
import HA.Services.SSPL ( __remoteTable, __remoteTableDecl )
import HA.Services.SSPLHL ( __remoteTable, __remoteTableDecl )
import HA.Stats ( __remoteTable )
import HA.RecoveryCoordinator.Definitions ( __remoteTable )

import Control.Distributed.Process (RemoteTable)

meroRemoteTable :: RemoteTable -> RemoteTable
meroRemoteTable next =
   HA.Resources.Castor.__remoteTable $
#ifdef USE_MERO
   HA.Resources.Mero.__remoteTable $
   HA.Resources.Mero.Note.__remoteTable $
   HA.Services.Mero.__remoteTableDecl $
   HA.Services.Mero.__remoteTable $
#endif
   HA.Services.SSPL.__remoteTable $
   HA.Services.SSPL.__remoteTableDecl $
   HA.Services.SSPLHL.__remoteTable $
   HA.Services.SSPLHL.__remoteTableDecl $
   HA.Services.Frontier.__remoteTable $
   HA.Services.Frontier.__remoteTableDecl $
   HA.Services.DecisionLog.__remoteTable $
   HA.Services.DecisionLog.__remoteTableDecl $
   HA.Services.Monitor.__remoteTable $
   HA.Services.Monitor.__remoteTableDecl $
   HA.Stats.__remoteTable $
   HA.RecoveryCoordinator.Definitions.__remoteTable $
   next
