-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- High-level bindings to the confc client library. confc allows programs to
-- get data from the Mero confd service.
--
-- The configuration data are organized in a tree.
--
module Mero.ConfC
  ( module Mero.Conf.Context
  , module Mero.Conf.Fid
  , module Mero.Conf.Obj
  , module Mero.Conf.Tree
  , withConf
  ) where

import Mero.Conf.Context
import Mero.Conf.Fid
import Mero.Conf.Internal (withConfC)
import Mero.Conf.Obj
import Mero.Conf.Tree

import Network.RPC.RPCLite
  ( RPCMachine
  , RPCAddress
  )

-- | Open a configuration tree at the root. Note that while the type
--   signatures of the functions to explore confc do not require so,
--   all other confc calls must be made within this scope or fail.
withConf :: RPCMachine
         -> RPCAddress
         -> (Root -> IO a)
         -> IO a
withConf m a f = withConfC $ withRoot m a f
