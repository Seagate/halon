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
  ( Fid )

import Control.Monad (liftM2)

import qualified Data.Map as Map

import Foreign.C.String
  ( newCString
  , peekCString
  )
import Foreign.Ptr (plusPtr)
import Foreign.Storable
  ( Storable(..) )

import qualified Language.C.Inline as C
import qualified Language.C.Inline.Context as C
import qualified Language.C.Types as C

#include "spiel/spiel.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

C.include "lib/memory.h"
C.include "spiel/spiel.h"

-- | m0_spiel_running_svc
data RunningService = RunningService {
    _rs_fid :: Fid
  , _rs_name :: String
}

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

spielCtx :: C.Context
spielCtx = mempty {
  C.ctxTypesTable = Map.fromList [
    (C.Struct "m0_spiel_running_svc", [t| RunningService |])
  ]
}
