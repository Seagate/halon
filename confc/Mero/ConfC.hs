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
  , withBitmap
  , withHASession
  , initHASession
  , finiHASession
  ) where

import Mero.Conf.Context
import Mero.Conf.Fid
import Mero.Conf.Internal (withConfC, withHASession, initHASession, finiHASession)
import Mero.Conf.Obj
import Mero.Conf.Tree

import Network.RPC.RPCLite
  ( RPCMachine
  , RPCAddress
  )

import Control.Exception (bracket_)
import Foreign.Ptr (Ptr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (poke)

-- | Open a configuration tree at the root. Note that while the type
--   signatures of the functions to explore confc do not require so,
--   all other confc calls must be made within this scope or fail.
withConf :: RPCMachine
         -> RPCAddress
         -> (Root -> IO a)
         -> IO a
withConf m a f = withConfC $ withRoot m a f

-- | Allocates and populates bitmap representation for mero.
withBitmap :: Bitmap -> (Ptr Bitmap -> IO a) -> IO a
withBitmap bm@(Bitmap n _) f = alloca $ \bm_ptr ->
  bracket_ (do bitmapInit bm_ptr ns
               poke bm_ptr bm)
           (bitmapFini bm_ptr)
           (f bm_ptr)
  where
    ns = fromIntegral n
