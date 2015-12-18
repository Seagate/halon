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
import HA.RecoveryCoordinator.Actions.Core
import HA.Services.Frontier.Command
import HA.Multimap (getKeyValuePairs)
import qualified HA.ResourceGraph as G
import Network.CEP

import Control.Distributed.Process

import Data.ByteString.Builder (toLazyByteString, lazyByteString)
import Data.Foldable (forM_)
import qualified Data.ByteString.Lazy as BL

-- | Merged frontiner rules. Indended to be used in RC.
frontierRules :: Definitions LoopState ()
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
ruleDumpKeyValues :: Definitions LoopState ()
ruleDumpKeyValues = defineSimple "frontiner-get-key-values" $
  \(HAEvent uuid (MultimapGetKeyValuePairs, pid) _) -> do
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
ruleDumpGraph :: Definitions LoopState ()
ruleDumpGraph = defineSimple "fontiner-dump-graph" $ 
  \(HAEvent uuid (ReadResourceGraph, pid) _) -> do
      rg   <- getLocalGraph
      _ <- liftProcess $ spawnLocal $ do
             let reply = dumpGraph $ G.getGraphResources rg
             mapM_ (usend pid) $ BL.toChunks 
                               $ toLazyByteString . lazyByteString $ reply
             usend pid ()
      messageProcessed uuid
