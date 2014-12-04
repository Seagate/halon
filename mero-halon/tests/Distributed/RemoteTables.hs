-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
{-#  LANGUAGE CPP #-}
module RemoteTables ( remoteTable ) where

import HA.Network.RemoteTables ( haRemoteTable )

import Control.Distributed.Process ( RemoteTable )
import Control.Distributed.Process.Node ( initRemoteTable )
import qualified Control.Distributed.Process.Debug as D

#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( __remoteTable, __remoteTableDecl )


remoteTable :: RemoteTable
remoteTable = __remoteTable $ __remoteTableDecl $ haRemoteTable initRemoteTable
#else
remoteTable :: RemoteTable
remoteTable = D.remoteTable $ haRemoteTable initRemoteTable
#endif
