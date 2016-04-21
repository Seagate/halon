-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE TypeFamilies #-}

module HA.Encode
  ( ProcessEncode(..) )
  where

import Control.Distributed.Process (Process)

-- | Type class to support encoding difficult types (e.g. existentials) using
--   Static machinery in the Process monad.
class ProcessEncode a where
  type BinRep a :: *
  encodeP :: a -> BinRep a
  decodeP :: BinRep a -> Process a
