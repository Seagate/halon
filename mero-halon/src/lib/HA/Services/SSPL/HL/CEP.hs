-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Contains RC rules that are required for SSPL HL service
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module HA.Services.SSPL.HL.CEP
  ( ssplHLRules
  ) where

import HA.EventQueue.Types
import HA.Resources
import HA.Resources.Castor
import qualified HA.ResourceGraph as G

import HA.RecoveryCoordinator.Actions.Core

import SSPL.Bindings
import Network.CEP

import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Aeson as Aeson
import qualified Data.Text as T
import Data.UUID (toString)
import Data.UUID.V4 (nextRandom)
import Control.Monad.State.Strict hiding (mapM_)
import Control.Distributed.Process (usend)
import Text.Regex.TDFA ((=~))

-- | Set of SSPL HL rules. Contain rules for status queries inside a graph.
ssplHLRules :: Definitions LoopState ()
ssplHLRules = defineSimple "status-query" $
  \(HAEvent uuid (CommandRequestMessageStatusRequest mef et,msgId, pid) _) -> do
      rg <- getLocalGraph
      let
        items = case et of
          Aeson.String "cluster" -> clusterStatus rg
          Aeson.String "node" -> hostStatus rg (fmap T.unpack mef)
          _ -> []
        msg = CommandResponseMessage {
              commandResponseMessageStatusResponse = Just items
            , commandResponseMessageResponseId = msgId
            , commandResponseMessageMessageId = Just . T.pack . toString $ uuid
            }
      liftProcess $ usend pid msg
      messageProcessed uuid


-- | Calculate the cluster status from the resource graph.
clusterStatus :: G.Graph -> [CommandResponseMessageStatusResponseItem]
clusterStatus g = CommandResponseMessageStatusResponseItem {
    commandResponseMessageStatusResponseItemEntityId = "cluster"
  , commandResponseMessageStatusResponseItemStatus = formatStatus status
  } : []
  where
    status = fromMaybe ONLINE . listToMaybe $ G.connectedTo Cluster Has g

    formatStatus :: ClusterStatus -> T.Text
    formatStatus = T.pack . show

-- | Calculate the node status for specified nodes from the resource graph.
hostStatus :: G.Graph
           -> Maybe String
           -> [CommandResponseMessageStatusResponseItem]
hostStatus rg regex = fmap (\h@(Host name) ->
      CommandResponseMessageStatusResponseItem {
        commandResponseMessageStatusResponseItemEntityId = T.pack name
      , commandResponseMessageStatusResponseItemStatus = status h
      }
    ) hosts
  where hosts = [ host | host@(Host hn) <- G.connectedTo Cluster Has rg
                       , hn =~? regex]
        a =~? (Just ef) = a =~ ef
        _ =~? Nothing = True
        status host = T.pack . show $ (G.connectedTo host Has rg :: [HostAttr])
