-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-#  LANGUAGE CPP #-}
module RemoteTables ( remoteTable ) where

import Mero.RemoteTables (meroRemoteTable)
import HA.Network.RemoteTables ( haRemoteTable )

import Control.Distributed.Process ( RemoteTable )
import Control.Distributed.Process.Node ( initRemoteTable )

#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( __remoteTableDecl )


remoteTable :: RemoteTable
remoteTable = __remoteTableDecl $ haRemoteTable $ meroRemoteTable initRemoteTable
#else
remoteTable :: RemoteTable
remoteTable = haRemoteTable $ meroRemoteTable initRemoteTable
#endif
