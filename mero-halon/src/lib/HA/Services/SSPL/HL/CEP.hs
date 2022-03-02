{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
-- |
-- Module    : HA.Services.SSPL.HL.CEP
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Contains RC rules that are required for SSPL HL service
module HA.Services.SSPL.HL.CEP
  ( ssplHLRules
  ) where

import           Data.Foldable                           (forM_)
import           Data.Maybe                              (catMaybes)
import qualified Data.Text                               as T
import           Data.UUID                               (toString)
import qualified HA.Aeson                                as Aeson
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero     (getClusterStatus)
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log   as Log
import qualified HA.ResourceGraph                        as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Resources.Mero
import           HA.Resources.Mero.Note                  (getState)
import           HA.Service                              (getInterface)
import           HA.Service.Interface
import           HA.Services.SSPL.LL.CEP
import           HA.Services.SSPL.LL.Resources
import           HA.Services.SSPLHL                      (SsplHlFromSvc (..),
                                                          SsplHlToSvc (..),
                                                          sspl)
import           Network.CEP
import           SSPL.Bindings
import           Text.Regex.TDFA                         ((=~))

-- | Set of SSPL HL rules. Contain rules for status queries inside a graph.
ssplHLRules :: Definitions RC ()
ssplHLRules = do
  let extract (HAEvent uid (SRequest v i nid)) _ = return $! Just (uid, v, i, nid)
      extract _ _ = return Nothing
    in defineSimpleIf "status-query" extract $
      \(uuid, CommandRequestMessageStatusRequest mef et, msgId, nid) -> do
          rg <- getGraph
          let
            items = case et of
              Aeson.String "cluster" -> clusterStatus rg
              Aeson.String "node"    -> hostStatus rg (fmap T.unpack mef)
              _                      -> []
            msg = CommandResponseMessage {
                  commandResponseMessageStatusResponse = Just items
                , commandResponseMessageResponseId = msgId
                , commandResponseMessageMessageId = Just . T.pack . toString $ uuid
                }
          Log.rcLog' Log.DEBUG $ "Sending reply " ++ show msg
          sendSvc (getInterface sspl) nid $! SResponse msg
          messageProcessed uuid

  defineSimpleIf "sspl-hl-node-cmd" (\(HAEvent uuid (CRequest cr)) _ ->
    return . fmap (uuid,) .  commandRequestMessageNodeStatusChangeRequest
              . commandRequestMessage
              $ cr
    ) $ \(uuid,sr) ->
      let
        command = commandRequestMessageNodeStatusChangeRequestCommand sr
        nodeFilter = case commandRequestMessageNodeStatusChangeRequestNodes sr of
          Just foo -> T.unpack foo
          Nothing  -> "."
      in do
        rg <- getGraph
        let nodes = [ n | n <- G.connectedTo Cluster Has rg
                        , Just m0n <- [nodeToM0Node n rg]
                        , getState m0n rg == NSOnline ]
        hosts <- fmap catMaybes $ findHosts nodeFilter >>= mapM findBMCAddress
        case command of
          Aeson.String "poweroff" -> do
            Log.rcLog' Log.DEBUG $ "Powering off hosts " ++ show hosts
            forM_ hosts $ \nodeIp -> do
              sendNodeCmd nodes Nothing $ IPMICmd IPMI_OFF (T.pack nodeIp)
          Aeson.String "poweron" -> do
            Log.rcLog' Log.DEBUG $ "Powering on hosts " ++ show hosts
            forM_ hosts $ \nodeIp -> do
              sendNodeCmd nodes Nothing $ IPMICmd IPMI_ON (T.pack nodeIp)
          x -> Log.rcLog' Log.WARN $ "Unsupported node command: " ++ show x
        messageProcessed uuid

-- | Calculate the cluster status from the resource graph.
clusterStatus :: G.Graph -> [CommandResponseMessageStatusResponseItem]
clusterStatus _g = CommandResponseMessageStatusResponseItem {
    commandResponseMessageStatusResponseItemEntityId = "cluster"
  , commandResponseMessageStatusResponseItemStatus = T.pack status
  } : []
  where
    status = maybe "No status" id $ prettyStatus <$> getClusterStatus _g


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
        status host = T.pack . show $
          (G.connectedTo host Has rg :: [HostAttr])
