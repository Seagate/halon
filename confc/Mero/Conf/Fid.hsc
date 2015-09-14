{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TupleSections #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero identifier type. Mero uses FIDs to uniquely identity most objects
-- it deals withm including items in the configuration database and files
-- stored in the filesystem.
--
module Mero.Conf.Fid
  ( Fid(..) ) where

#include "confc_helpers.h"
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

import Control.Monad ( liftM2 )
import Data.Binary (Binary)
import Data.Data (Data)
import Data.Hashable (Hashable)
import Data.Typeable ( Typeable )
import Data.Word ( Word64 )
import Foreign.Storable ( Storable(..) )
import GHC.Generics ( Generic )
import Text.Printf (printf)

-- | Representation of @struct m0_fid@. It is an identifier for objects in
-- confc.
data Fid = Fid { f_container :: {-# UNPACK #-} !Word64
               , f_key       :: {-# UNPACK #-} !Word64
               }
  deriving (Eq, Data, Ord, Typeable, Generic)

instance Show Fid where
  show (Fid c k) = printf "Fid {f_container = 0x%08x, f_key = %d}" c k

instance Binary Fid
instance Hashable Fid

instance Storable Fid where
  sizeOf    _           = #{size struct m0_fid}
  alignment _           = #{alignment struct m0_fid}
  peek      p           = liftM2 Fid
                            (#{peek struct m0_fid, f_container} p)
                            (#{peek struct m0_fid, f_key} p)
  poke      p (Fid c k) = do #{poke struct m0_fid, f_container} p c
                             #{poke struct m0_fid, f_key} p k
