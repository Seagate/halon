-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}
module Mero.RemoteTables (meroRemoteTable) where

#ifdef USE_MERO
import HA.Resources.Mero ( __remoteTable )
#endif

import HA.Services.Mero ( __remoteTableDecl )
import HA.Services.SSPL ( __remoteTable, __remoteTableDecl )
import HA.RecoveryCoordinator.Definitions ( __remoteTable )

import Control.Distributed.Process (RemoteTable)

meroRemoteTable :: RemoteTable -> RemoteTable
meroRemoteTable next =
#ifdef USE_MERO
   HA.Resources.Mero.__remoteTable $
#endif
   HA.Services.Mero.__remoteTableDecl $
   HA.Services.SSPL.__remoteTable $
   HA.Services.SSPL.__remoteTableDecl $
   HA.RecoveryCoordinator.Definitions.__remoteTable $
   next
