-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

module RemoteTables ( remoteTable ) where

import HA.Network.RemoteTables ( haRemoteTable )
import HA.Replicator.Mock ( __remoteTableDecl )

import Control.Distributed.Process ( RemoteTable )
import Control.Distributed.Process.Node ( initRemoteTable )


remoteTable :: RemoteTable
remoteTable = __remoteTableDecl $ haRemoteTable initRemoteTable
