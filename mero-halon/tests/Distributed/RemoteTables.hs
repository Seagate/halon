-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
{-#  LANGUAGE CPP #-}
module RemoteTables ( remoteTable ) where

import HA.Network.RemoteTables ( haRemoteTable )
import HA.Replicator.Mock ( __remoteTable, __remoteTableDecl )

import Control.Distributed.Process ( RemoteTable )
import Control.Distributed.Process.Node ( initRemoteTable )
import qualified Control.Distributed.Process.Debug as D


remoteTable :: RemoteTable
remoteTable = __remoteTable $ __remoteTableDecl $ haRemoteTable initRemoteTable
