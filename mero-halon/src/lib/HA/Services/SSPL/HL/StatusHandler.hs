-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module HA.Services.SSPL.HL.StatusHandler where

import Prelude hiding ((<$>), (<*>), id, mapM_)
import HA.EventQueue.Producer (promulgate)
import HA.RecoveryCoordinator.Mero (GetMultimapProcessId(..))
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Mero

import SSPL.Bindings

import Control.Distributed.Process
  ( Process
  , ProcessId
  , SendPort
  , expect
  , getSelfPid
  , say
  , sendChan
  , spawnLocal
  )
import Control.Monad.State.Strict hiding (mapM_)

import qualified Data.Aeson as Aeson
import qualified Data.Text as T
import Data.UUID (toString)
import Data.UUID.V4 (nextRandom)

import Text.Regex.TDFA ((=~))

start :: SendPort CommandResponseMessage
      -> Process ProcessId
start sp = spawnLocal $ do
    void $ getSelfPid >>= promulgate . GetMultimapProcessId
    expect >>= go
  where
    go mmid = forever $ do
      cr <- expect
      rg <- G.getGraph mmid
      uuid <- liftIO $ nextRandom
      let (CommandRequestMessage _ _ msr msgId) = commandRequestMessage cr
      case msr of
        Just (CommandRequestMessageStatusRequest mef et) ->
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
          in sendChan sp msg
        Nothing -> say "Error: No status request in message."

-- | Calculate the cluster status from the resource graph.
clusterStatus :: G.Graph -> [CommandResponseMessageStatusResponseItem]
clusterStatus _ = CommandResponseMessageStatusResponseItem {
    commandResponseMessageStatusResponseItemEntityId = "cluster"
  , commandResponseMessageStatusResponseItemStatus = "ok"
  } : []

-- | Calculate the node status for specified nodes from the resource graph.
hostStatus :: G.Graph
           -> Maybe String
           -> [CommandResponseMessageStatusResponseItem]
hostStatus rg regex = fmap (\(Host name) ->
      CommandResponseMessageStatusResponseItem {
        commandResponseMessageStatusResponseItemEntityId = T.pack name
      , commandResponseMessageStatusResponseItemStatus = "ok"
      }
    ) hosts
  where hosts = [ host | host@(Host hn) <- G.connectedTo Cluster Has rg
                       , hn =~? regex]
        a =~? (Just ef) = a =~ ef
        _ =~? Nothing = True
