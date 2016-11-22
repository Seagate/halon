-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
-- Module with rules for frontier service that should be running on RC
-- side
module HA.Services.Frontier.CEP
  ( frontierRules
    -- * Individual rules
  , ruleDumpKeyValues
  , ruleDumpGraph
  ) where

import HA.EventQueue.Types
import HA.RecoveryCoordinator.RC.Actions
import HA.Services.Frontier.Command
import HA.Multimap (getKeyValuePairs)
import qualified HA.ResourceGraph as G
import Network.CEP

import Control.Distributed.Process

import Data.ByteString.Builder (toLazyByteString, lazyByteString)
import qualified Data.ByteString.Lazy as BL

-- | Merged frontiner rules. Indended to be used in RC.
frontierRules :: Definitions RC ()
frontierRules = sequence_
  [ ruleDumpKeyValues
  , ruleDumpGraph
  ]

-- | Individual rule. Reads all key values in storage and sends that to
-- the caller. Reply it send as a stream of a 'Data.ByteString.ByteString's
-- followed by '()' when everything is sent.
--
-- This call marked as proccessed immediately and is not reprocessed if case
-- of RC failure.
ruleDumpKeyValues :: Definitions RC ()
ruleDumpKeyValues = defineSimple "frontiner-get-key-values" $
  \(HAEvent uuid (MultimapGetKeyValuePairs, pid)) -> do
      chan <- lsMMChan <$> get Global
      _ <- liftProcess $ spawnLocal $ do
             reply <- mmKeyValues . Just <$> getKeyValuePairs chan
             mapM_ (usend pid) $ BL.toChunks
                               $ toLazyByteString . lazyByteString $ reply
             usend pid ()
      messageProcessed uuid

-- | Individual rule. Reads graph and sends serializes that into graphviz
-- format. Reply it send as a stream of a 'Data.ByteString.ByteString's
-- followed by '()' when everything is sent.
--
-- This call marked as proccessed immediately and is not reprocessed if case
-- of RC failure.
ruleDumpGraph :: Definitions RC ()
ruleDumpGraph = defineSimple "frontier-dump-graph" $
  \(HAEvent uuid (ReadResourceGraph, pid)) -> do
      rg   <- getLocalGraph
      _ <- liftProcess $ spawnLocal $ do
             let reply = dumpGraph $ G.getGraphResources rg
             say "start sending graph"
             mapM_ (usend pid) $ BL.toChunks
                               $ toLazyByteString . lazyByteString $ reply
             usend pid ()
             say "finished sending graph"
      messageProcessed uuid
