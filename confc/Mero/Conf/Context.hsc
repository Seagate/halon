{-# LANGUAGE CApiFFI                    #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ForeignFunctionInterface   #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}

-- |
-- Copyright : (C) 2015-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- inline-c context for the conf interface.
--

module Mero.Conf.Context
  ( Bitmap(..)
  , Cookie(..)
  , PDClustAttr(..)
  , Word128(..)
  , bitmapInit
  , bitmapFini
  , bitmapFromArray
  ) where

import Control.Monad (when)
import Data.Aeson (FromJSON, ToJSON)
import Data.Binary (Binary)
import Data.Bits (setBit, shiftR, zeroBits)
import Data.Data (Data)
import Data.Hashable (Hashable)
import Data.List (splitAt, foldl')
import Data.SafeCopy
import Data.Serialize
import Data.Word (Word32, Word64)

import Foreign.Marshal.Array (peekArray, pokeArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (Storable(..))
import GHC.Generics (Generic)
import Language.C.Inline (CInt(..))

#include "layout/pdclust.h"
#include "lib/bitmap.h"
#include "lib/cookie.h"
#include "lib/types.h"

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
   c_bitmap_init :: Ptr Bitmap -> CInt -> IO CInt

foreign import capi unsafe "lib/bitmap.h m0_bitmap_fini"
   bitmapFini :: Ptr Bitmap -> IO ()

bitmapFromArray :: [Bool] -> Bitmap
bitmapFromArray bs = Bitmap n $ go [] bs where
  go acc arr = case splitAt 64 arr of
    ([], _) -> acc
    (x, xs) -> bits2word x : go acc xs
  bits2word xs = foldl'
    (\bm (idx, a) -> if a then setBit bm idx else bm)
    zeroBits
    (zip [0 .. length xs - 1] xs)
  n = length bs

-- @types.h m0_unit128@
data Word128 = Word128 {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
  deriving (Eq, Ord, Data, Generic, Show)

instance FromJSON Word128
instance ToJSON Word128
instance Binary Word128
instance Serialize Word128
instance SafeCopy Word128 where
  kind = primitive
instance Hashable Word128
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
data PDClustAttr = PDClustAttr
  { _pa_N :: Word32          -- ^ number of data units in a parity group
  , _pa_K :: Word32          -- ^ number of parity units
  , _pa_P :: Word32          -- ^ pool width
  , _pa_unit_size :: Word64  -- ^ stripe unit size, bytes
  , _pa_seed :: Word128
} deriving (Eq, Generic, Show)

instance Binary PDClustAttr
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

deriveSafeCopy 0 'base ''PDClustAttr
instance ToJSON PDClustAttr
