-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

module RemoteTables ( remoteTable ) where

import HA.Network.RemoteTables ( haRemoteTable )
import HA.Replicator.Mock ( __remoteTableDecl )

import Control.Distributed.Process ( RemoteTable )
import Control.Distributed.Process.Node ( initRemoteTable )


remoteTable :: RemoteTable
remoteTable = __remoteTableDecl $ haRemoteTable initRemoteTable
