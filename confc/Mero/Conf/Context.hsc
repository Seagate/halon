{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- inline-c context for the conf interface.
--

module Mero.Conf.Context where

import Mero.Conf.Fid ( Fid(..) )

import Control.Monad (when)
import Data.Aeson (FromJSON, ToJSON)
import Data.Binary (Binary)
import Data.Bits
  ( setBit
  , shiftR
  , zeroBits
  )
import Data.Data (Data)
import Data.Hashable (Hashable)
import qualified Data.List as List
import qualified Data.Map as Map
import Data.SafeCopy
import Data.Serialize
import Data.Word ( Word32, Word64 )

import Foreign.Marshal.Array
  ( peekArray
  , pokeArray
  )
import Foreign.Ptr
  ( Ptr
  , nullPtr
  )
import Foreign.Storable
  ( Storable(..) )
import GHC.Generics

import qualified Language.C.Inline as C
import qualified Language.C.Inline.Context as C
import qualified Language.C.Types as C

#include "confc_helpers.h"
#include "layout/pdclust.h"
#include "lib/bitmap.h"
#include "lib/types.h"

#if __GLASGOW_HASKELL__ < 800
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)
#endif

-- @bitmap.h m0_bitmap@
data Bitmap = Bitmap !Int [Word64]
  deriving (Eq, Show, Generic)

instance Binary Bitmap
instance Hashable Bitmap
instance ToJSON Bitmap
instance FromJSON Bitmap
deriveSafeCopy 0 'base ''Bitmap

-- | Bitmap structure is complex, so in order to poke
-- value to the memory, that memory should be prepared first.
-- This could be done my invoking 'm0_bitmap_init' and providing
-- correct size. It's better to use withBitmap wrapper for that.
instance Storable Bitmap where
  sizeOf _ = #{size struct m0_bitmap}
  alignment _ = #{alignment struct m0_bitmap}
  peek p = do
      nr <- (#{peek struct m0_bitmap, b_nr} p)
      let wordsn = bits2words nr
      ptr <- #{peek struct m0_bitmap, b_words} p
      w <- (peekArray wordsn ptr :: IO [Word64])
      return $ Bitmap nr w
    where
      bits2words bits = (bits + 63) `shiftR` 6

  poke p (Bitmap nr b) = do
      pr <- #{peek struct m0_bitmap, b_nr} p
      when (pr /= nr) $ error $ "bitmap structure was not prepared to store bitmap" ++ show (pr, nr)
      ptr <- #{peek struct m0_bitmap, b_words} p
      when (ptr == nullPtr) $ error "bitmap array was not allocated"
      pokeArray ptr b

bitmapInit :: Ptr Bitmap -> Int -> IO ()
bitmapInit bmptr sz = do
  rc <- c_bitmap_init bmptr (fromIntegral sz)
  when (rc /= 0) $ error "Bitmap can't be allocated"

foreign import capi unsafe "lib/bitmap.h m0_bitmap_init"
   c_bitmap_init :: Ptr Bitmap -> C.CInt -> IO C.CInt

foreign import capi unsafe "lib/bitmap.h m0_bitmap_fini"
   bitmapFini :: Ptr Bitmap -> IO ()

bitmapFromArray :: [Bool] -> Bitmap
bitmapFromArray bs = Bitmap n $ go [] bs where
  go acc arr = case List.splitAt 64 arr of
    ([], _) -> acc
    (x, xs) -> bits2word x : go acc xs
  bits2word xs = List.foldl'
    (\bm (idx, a) -> case a of
      False -> bm
      True -> setBit bm idx
    )
    zeroBits
    (zip [0 .. length xs - 1] xs)
  n = length bs

-- @types.h m0_unit128@
data Word128 = Word128 {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
  deriving (Eq, Ord, Generic, Show)

instance Binary Word128
instance Data Word128
instance FromJSON Word128
instance ToJSON Word128
instance Hashable Word128
instance Serialize Word128
instance SafeCopy Word128 where
  kind = primitive
instance Storable Word128 where
  sizeOf _ = #{size struct m0_uint128}
  alignment _ = #{alignment struct m0_uint128}
  peek p = Word128
    <$> #{peek struct m0_uint128, u_hi} p
    <*> #{peek struct m0_uint128, u_lo} p
  poke p (Word128 hi lo) = do
    #{poke struct m0_uint128, u_hi} p hi
    #{poke struct m0_uint128, u_lo} p lo

-- @types.h m0_cookie@
data Cookie = Cookie {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
  deriving (Eq, Generic, Show)

instance Binary Cookie
instance Hashable Cookie
instance Storable Cookie where
  sizeOf _ = #{size struct m0_cookie}
  alignment _ = #{alignment struct m0_cookie}
  peek p = Cookie
    <$> #{peek struct m0_cookie, co_addr} p
    <*> #{peek struct m0_cookie, co_generation} p
  poke p (Cookie addr gen) = do
    #{poke struct m0_cookie, co_addr} p addr
    #{poke struct m0_cookie, co_generation} p gen

-- | @pdclust.h m0_pdclust_attr@
data PDClustAttr = PDClustAttr {
    pa_N :: Word32
  , pa_K :: Word32
  , pa_P :: Word32
  , pa_unit_size :: Word64
  , pa_seed :: Word128
} deriving (Eq, Data, Generic, Show)

instance Binary PDClustAttr
instance FromJSON PDClustAttr
instance Hashable PDClustAttr
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
    , (C.Struct "m0_cookie", [t| Cookie |])
    , (C.Struct "m0_pdclust_attr", [t| PDClustAttr |])
    , (C.Struct "m0_bitmap", [t| Bitmap |])
  ]
}

deriveSafeCopy 0 'base ''PDClustAttr
instance ToJSON PDClustAttr
