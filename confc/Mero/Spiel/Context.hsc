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
  , ServiceParams(..)
  , ServiceType(..)
  )

import Control.Monad (liftM2)

import qualified Data.Map as Map
import Data.Word ( Word32 )

import Foreign.C.String
  ( CString
  , newCString
  , peekCString
  )
import Foreign.C.Types ( CInt )
import Foreign.Marshal.Array
  ( advancePtr
  , newArray0
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

#include "spiel/spiel.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

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

spielCtx :: C.Context
spielCtx = mempty {
  C.ctxTypesTable = Map.fromList [
      (C.Struct "m0_spiel_running_svc", [t| RunningService |])
    , (C.Struct "m0_spiel_service_info", [t| ServiceInfo |])
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
