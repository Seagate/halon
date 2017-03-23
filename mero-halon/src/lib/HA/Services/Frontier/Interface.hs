{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.Services.Frontier.Interface
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- 'Interface' for the Frontier service.
module HA.Services.Frontier.Interface
  ( interface
  , FrontierCmd(..)
  , FrontierReply(..)
  , module HA.Service.Interface
  ) where

import           Control.Distributed.Process (ProcessId)
import qualified Data.ByteString as B
import           HA.SafeCopy
import           HA.Service.Interface

data FrontierCmd
  = MultimapGetKeyValuePairs !ProcessId
  -- ^ Retrieve multimap in pairs of k:v
  | ReadResourceGraph !ProcessId
  -- ^ Read the data from RG directly
  | JsonGraph !ProcessId
  -- ^ Read the data from RG and dump it out to JSON
  deriving (Show, Eq, Ord)

data FrontierReply
  = FrontierChunk !B.ByteString
    -- ^ A chunk of data sent to us from RC.
  | FrontierDone
    -- ^ RC is done sending data.
  deriving (Show, Eq, Ord)

-- | Frontier service 'Interface'.
interface :: Interface FrontierReply FrontierCmd
interface = Interface
  { ifVersion = 0
  , ifServiceName = "frontier"
  , ifEncodeToSvc = \_v -> Just . safeEncode interface
  , ifDecodeToSvc = safeDecode
  , ifEncodeFromSvc = \_v -> Just . safeEncode interface
  , ifDecodeFromSvc = safeDecode
  }

deriveSafeCopy 0 'base ''FrontierCmd
deriveSafeCopy 0 'base ''FrontierReply
