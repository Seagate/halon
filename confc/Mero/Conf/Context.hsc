{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- inline-c context for the conf interface.
--

module Mero.Conf.Context where

import Mero.Conf.Fid ( Fid(..) )

import qualified Data.Map as Map
import Data.Word ( Word32, Word64 )

import Foreign.Marshal.Array
  ( peekArray
  , pokeArray
  )
import Foreign.Ptr
  ( plusPtr )
import Foreign.Storable
  ( Storable(..) )

import qualified Language.C.Inline as C
import qualified Language.C.Inline.Context as C
import qualified Language.C.Types as C

#include "confc_helpers.h"
#include "layout/pdclust.h"
#include "lib/bitmap.h"
#include "lib/types.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

-- @bitmap.h m0_bitmap@
newtype Bitmap = Bitmap [Word64]
  deriving (Eq, Show)

instance Storable Bitmap where
  sizeOf _ = #{size struct m0_bitmap}
  alignment _ = #{alignment struct m0_bitmap}
  peek p = do
      nr <- #{peek struct m0_bitmap, b_nr} p
      w <- (peekArray nr (#{ptr struct m0_bitmap, b_words} p) :: IO [Word64])
      return $ Bitmap w

  poke p (Bitmap b) = do
    #{poke struct m0_bitmap, b_nr} p $ length b
    pokeArray (#{ptr struct m0_bitmap, b_words} p) b

-- @types.h m0_unit128@
data Word128 = Word128 {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
  deriving (Eq, Show)

instance Storable Word128 where
  sizeOf _ = #{size struct m0_uint128}
  alignment _ = #{alignment struct m0_uint128}
  peek p = Word128
    <$> #{peek struct m0_uint128, u_hi} p
    <*> #{peek struct m0_uint128, u_lo} p
  poke p (Word128 hi lo) = do
    #{poke struct m0_uint128, u_hi} p hi
    #{poke struct m0_uint128, u_lo} p lo

-- | @pdclust.h m0_pdclust_attr@
data PDClustAttr = PDClustAttr {
    _pa_N :: Word32
  , _pa_K :: Word32
  , _pa_P :: Word32
  , _pa_unit_size :: Word64
  , _pa_seed :: Word128
} deriving (Eq, Show)

instance Storable PDClustAttr where
  sizeOf _ = #{size struct m0_pdclust_attr}
  alignment _ = #{alignment struct m0_pdclust_attr}
  peek p = PDClustAttr
    <$> #{peek struct m0_pdclust_attr, pa_N} p
    <*> #{peek struct m0_pdclust_attr, pa_K} p
    <*> #{peek struct m0_pdclust_attr, pa_P} p
    <*> #{peek struct m0_pdclust_attr, pa_unit_size} p
    <*> #{peek struct m0_pdclust_attr, pa_seed} p
  poke p (PDClustAttr n k p' u s) = do
    #{poke struct m0_pdclust_attr, pa_N} p n
    #{poke struct m0_pdclust_attr, pa_K} p k
    #{poke struct m0_pdclust_attr, pa_P} p p'
    #{poke struct m0_pdclust_attr, pa_unit_size} p u
    #{poke struct m0_pdclust_attr, pa_seed} p s

confCtx :: C.Context
confCtx = mempty {
  C.ctxTypesTable = Map.fromList [
      (C.Struct "m0_fid", [t| Fid |])
    , (C.Struct "m0_uint128", [t| Word128 |])
    , (C.Struct "m0_pdclust_attr", [t| PDClustAttr |])
    , (C.Struct "m0_bitmap", [t| Bitmap |])
  ]
}
