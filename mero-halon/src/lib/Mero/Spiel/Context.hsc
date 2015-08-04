{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- inline-c context for the spiel interface.
--

module Mero.Spiel.Context where

import Mero.ConfC
  ( Fid
  , ServiceType(..)
  )

import Control.Monad (liftM2)

import qualified Data.Map as Map
import Data.Word ( Word32, Word64 )

import Foreign.C.String
  ( CString
  , newCString
  , peekCString
  )
import Foreign.C.Types ( CInt )
import Foreign.Marshal.Array
  ( advancePtr
  , newArray0
  , peekArray
  , pokeArray
  )
import Foreign.Ptr
  ( Ptr
  , nullPtr
  , plusPtr
  )
import Foreign.Storable
  ( Storable(..) )

import qualified Language.C.Inline as C
import qualified Language.C.Inline.Context as C
import qualified Language.C.Types as C

import System.IO.Unsafe ( unsafePerformIO )

#include "layout/pdclust.h"
#include "lib/bitmap.h"
#include "lib/types.h"
#include "spiel/spiel.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

C.include "layout/pdclust.h"
C.include "lib/bitmap.h"
C.include "lib/memory.h"
C.include "lib/types.h"
C.include "spiel/spiel.h"

-- | @spiel.h m0_spiel_running_svc@
data RunningService = RunningService {
    _rs_fid :: Fid
  , _rs_name :: String
} deriving (Eq, Show)

instance Storable RunningService where
  sizeOf _ = #{size struct m0_spiel_running_svc}
  alignment _ = #{alignment struct m0_spiel_running_svc}
  peek p = liftM2 RunningService
    (#{peek struct m0_spiel_running_svc, spls_fid} p)
    (peekCString $ #{ptr struct m0_spiel_running_svc, spls_name} p)

  poke p (RunningService f n) = do
    c_name <- newCString n
    #{poke struct m0_spiel_running_svc, spls_fid} p f
    #{poke struct m0_spiel_running_svc, spls_name} p c_name

-- @bitmap.h m0_bitmap@
newtype Bitmap = Bitmap [Bool]

instance Storable Bitmap where
  sizeOf _ = #{size struct m0_bitmap}
  alignment _ = #{alignment struct m0_bitmap}
  peek p = do
      nr <- #{peek struct m0_bitmap, b_nr} p
      w <- (peekArray nr (#{ptr struct m0_bitmap, b_words} p) :: IO [Word64])
      return . Bitmap $ map toBool w
    where
      toBool w = case w of
        0 -> False
        _ -> True

  poke p (Bitmap b) = do
    #{poke struct m0_bitmap, b_nr} p $ length b
    pokeArray (#{ptr struct m0_bitmap, b_words} p) b

data ServiceParams =
      SPRepairLimits !Word32
    | SPADDBStobFid !Fid
    | SPConfDBPath String
    | SPUnused
  deriving (Eq, Show)

instance Storable ServiceParams where

-- @spiel.h m0_spiel_service_info@
data ServiceInfo = ServiceInfo {
    _svi_type :: ServiceType
  , _svi_endpoints :: [String]
  , _svi_u :: ServiceParams
} deriving (Eq, Show)

instance Storable ServiceInfo where
  sizeOf _ = #{size struct m0_spiel_service_info}
  alignment _ = #{alignment struct m0_spiel_service_info}
  peek p = do
    st <- fmap (toEnum . fromIntegral) $
            (#{peek struct m0_spiel_service_info, svi_type} p :: IO CInt)
    ep <- peekStringArray (#{ptr struct m0_spiel_service_info, svi_endpoints} p)
    u <- case st of
      CST_MGS -> fmap SPConfDBPath $ peekCString $
        #{ptr struct m0_spiel_service_info, svi_u} p
      _ -> return SPUnused
    return $ ServiceInfo st ep u

  poke p (ServiceInfo t e u) = do
    #{poke struct m0_spiel_service_info, svi_type} p $ fromEnum t
    cstrs <- mapM newCString e
    cstr_arr_ptr <- newArray0 nullPtr cstrs
    #{poke struct m0_spiel_service_info, svi_endpoints} p cstr_arr_ptr
    case u of
      SPRepairLimits w -> #{poke struct m0_spiel_service_info, svi_u} p w
      SPADDBStobFid f -> #{poke struct m0_spiel_service_info, svi_u} p f
      SPConfDBPath c -> newCString c >>= \cs ->
                          #{poke struct m0_spiel_service_info, svi_u} p cs
      SPUnused -> return ()

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

spielCtx :: C.Context
spielCtx = mempty {
  C.ctxTypesTable = Map.fromList [
      (C.Struct "m0_uint128", [t| Word128 |])
    , (C.Struct "m0_pdclust_attr", [t| PDClustAttr |])
    , (C.Struct "m0_spiel_running_svc", [t| RunningService |])
    , (C.Struct "m0_spiel_service_info", [t| ServiceInfo |])
    , (C.Struct "m0_bitmap", [t| Bitmap |])
  ]
}

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

peekStringArray :: Ptr CString -> IO [String]
peekStringArray p = mapM peekCString
                  $ takeWhile (/=nullPtr)
                  $ map (unsafePerformIO . peek)
                  $ iterate (`advancePtr` 1) p

