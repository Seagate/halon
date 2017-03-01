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

import           Control.Distributed.Process (NodeId)
import qualified Data.ByteString as B
import           Data.Serialize.Get (runGet)
import           Data.Serialize.Put (runPut)
import           HA.SafeCopy
import           HA.Service.Interface

data FrontierCmd
  = MultimapGetKeyValuePairs !NodeId
  -- ^ Retrieve multimap in pairs of k:v
  | ReadResourceGraph !NodeId
  -- ^ Read the data from RG directly
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
  , ifEncodeToSvc = \_v -> Just . mkWf . runPut . safePut
  , ifDecodeToSvc = \wf -> case runGet safeGet $! wfPayload wf of
    Left{} -> Nothing
    Right !v -> Just v
  , ifEncodeFromSvc = \_v -> Just . mkWf . runPut . safePut
  , ifDecodeFromSvc = \wf -> case runGet safeGet $! wfPayload wf of
      Left{} -> Nothing
      Right !v -> Just v
  }
  where
    mkWf payload = WireFormat
      { wfServiceName = ifServiceName interface
      , wfVersion = ifVersion interface
      , wfPayload = payload
      }

deriveSafeCopy 0 'base ''FrontierCmd
deriveSafeCopy 0 'base ''FrontierReply
