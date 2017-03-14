-- |
-- Module    : HA.Services.Frontier.CEP
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
--
-- Module with rules for frontier service that should be running on RC
-- side
module HA.Services.Frontier.CEP ( frontierRules ) where

import           Control.Distributed.Process
import           Control.Monad (void)
import           Data.ByteString.Builder (toLazyByteString, lazyByteString)
import qualified Data.ByteString.Lazy as BL
import           HA.EventQueue (HAEvent(..))
import           HA.Multimap (getKeyValuePairs)
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.ResourceGraph as G
import           HA.Service.Interface
import           HA.Services.Frontier
import           HA.Services.Frontier.Command
import           Network.CEP

-- | Merged frontiner rules. Indended to be used in RC.
frontierRules :: Definitions RC ()
frontierRules = sequence_ [ ruleDump ]

-- | Dump k-v/rg value out to the service.
--
-- This call marked as proccessed immediately and is not reprocessed if case
-- of RC failure.
ruleDump :: Definitions RC ()
ruleDump = defineSimple "frontier-dump-values" $ \(HAEvent uuid msg) -> case msg of
  -- Reads all key values in storage and sends that to
  -- the caller. Reply it send as a stream of a 'Data.ByteString.ByteString's
  -- followed by '()' when everything is sent.
  MultimapGetKeyValuePairs nid -> do
    messageProcessed uuid
    chan <- lsMMChan <$> get Global
    void . liftProcess $ spawnLocal $ do
      reply <- mmKeyValues . Just <$> getKeyValuePairs chan
      mapM_ (sendSvc (getInterface frontier) nid . FrontierChunk)
        $ BL.toChunks
        $ toLazyByteString . lazyByteString $ reply
      sendSvc (getInterface frontier) nid FrontierDone
  -- Reads graph and sends serializes that into graphviz
  -- format. Reply is send as a stream of a 'Data.ByteString.ByteString's
  -- followed by '()' when everything is sent.
  ReadResourceGraph nid -> do
    messageProcessed uuid
    rg <- getLocalGraph
    void . liftProcess $ spawnLocal $ do
      let reply = dumpGraph $ G.getGraphResources rg
      say "start sending graph"
      mapM_ (sendSvc (getInterface frontier) nid . FrontierChunk)
        $ BL.toChunks
        $ toLazyByteString . lazyByteString $ reply
      sendSvc (getInterface frontier) nid FrontierDone
      say "finished sending graph"
