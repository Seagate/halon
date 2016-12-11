-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-#  LANGUAGE CPP #-}
module RemoteTables ( remoteTable ) where

import Mero.RemoteTables (meroRemoteTable)
import HA.Network.RemoteTables ( haRemoteTable )
import HA.Replicator.Mock ( __remoteTableDecl )
#ifdef USE_MERO
import qualified HA.Services.Mero.Mock (__remoteTableDecl)
#endif

import Control.Distributed.Process ( RemoteTable )
import Control.Distributed.Process.Node ( initRemoteTable )


remoteTable :: RemoteTable
remoteTable = __remoteTableDecl
#ifdef USE_MERO
  $ HA.Services.Mero.Mock.__remoteTableDecl
#endif
  $ haRemoteTable $ meroRemoteTable initRemoteTable
