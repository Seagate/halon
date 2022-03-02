-- |
-- Copyright : (C) 2013-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
module Mero.ConfC
  ( module Mero.Conf.Context
  , module Mero.Conf.Fid
  , module Mero.Conf.Obj
  , withBitmap
  ) where

import Mero.Conf.Context
import Mero.Conf.Fid
import Mero.Conf.Obj

import Control.Exception (bracket_)
import Foreign.Ptr (Ptr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (poke)

-- | Allocates and populates bitmap representation for mero.
withBitmap :: Bitmap -> (Ptr Bitmap -> IO a) -> IO a
withBitmap bm@(Bitmap n _) f = alloca $ \bm_ptr ->
  bracket_ (bitmapInit bm_ptr ns >> poke bm_ptr bm)
           (bitmapFini bm_ptr)
           (f bm_ptr)
  where
    ns = fromIntegral n
