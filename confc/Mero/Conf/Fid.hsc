{-# LANGUAGE CApiFFI                  #-}
{-# LANGUAGE DeriveDataTypeable       #-}
{-# LANGUAGE DeriveGeneric            #-}
{-# LANGUAGE EmptyDataDecls           #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf               #-}
{-# LANGUAGE TupleSections            #-}
-- |
-- Copyright : (C) 2015-2018 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Mero identifier type. Mero uses FIDs to uniquely identity most objects
-- it deals with including items in the configuration database and files
-- stored in the filesystem.
--
module Mero.Conf.Fid
  ( Fid(..)
  , fidToStr
  , strToFid
  , m0_fid0
  ) where

#include "fid/fid.h"

import           Control.Monad (liftM2)
import           Data.Aeson (FromJSON, ToJSON)
import           Data.Binary (Binary)
import           Data.Data (Data)
import           Data.Hashable (Hashable)
import           Data.SafeCopy
import           Data.Serialize
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import           Data.Word (Word64)
import           Foreign.Storable (Storable(..))
import           GHC.Generics (Generic)
import           Text.Printf (printf)
import           Text.Read (readMaybe)

-- | Representation of @struct m0_fid@. It is an identifier for objects in
-- confc.
data Fid = Fid { f_container :: {-# UNPACK #-} !Word64
               , f_key       :: {-# UNPACK #-} !Word64
               }
  deriving (Eq, Data, Ord, Typeable, Generic)

instance Show Fid where
  show = fidToStr

-- | Convert a 'Fid' to 'String' in a format that is expected in
-- various locations read by mero, such as part of filenames.
fidToStr :: Fid -> String
fidToStr (Fid c k) = printf "0x%x:0x%x" c k

-- | Try to parse a 'String' into a 'Fid'. The input should be in a
-- format that 'fidToStr' would produce.
strToFid :: String -> Maybe Fid
strToFid mfid = case readMaybe <$> breakFid mfid of
  [Just container, Just key] -> Just $ Fid container key
  _ -> Nothing
  where
    breakFid = map T.unpack . T.splitOn (T.singleton ':') . T.pack

instance Binary Fid
instance Hashable Fid
instance FromJSON Fid
instance ToJSON Fid
instance Serialize Fid
instance SafeCopy Fid where
  kind = primitive

instance Storable Fid where
  sizeOf    _           = #{size struct m0_fid}
  alignment _           = #{alignment struct m0_fid}
  peek      p           = liftM2 Fid
                            (#{peek struct m0_fid, f_container} p)
                            (#{peek struct m0_fid, f_key} p)
  poke      p (Fid c k) = do #{poke struct m0_fid, f_container} p c
                             #{poke struct m0_fid, f_key} p k
-- | @fid/fid.h M0_FID0@
m0_fid0 :: Fid
m0_fid0 = Fid 0 0
