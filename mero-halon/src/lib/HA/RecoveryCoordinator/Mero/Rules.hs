{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules and primitives specific to Mero

module HA.RecoveryCoordinator.Mero.Rules where

import qualified Data.UUID as UUID
import HA.EventQueue
import HA.ResourceGraph as G
import HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Mero.Events
import HA.RecoveryCoordinator.Service.Events
import qualified HA.RecoveryCoordinator.Mero.Rules.Maintenance as M
import HA.Resources.Mero.Note
import qualified HA.Resources.Mero as M0
import qualified HA.Resources        as R
import HA.Services.Mero
import Mero.Notification (Get(..), GetReply(..))
import Mero.Notification.HAState (Note(..))

import Control.Lens
import Control.Distributed.Process (usend, sendChan)

import Network.CEP

import Prelude hiding (id)

-- | Timeout between entrypoint retry.
entryPointTimeout :: Int
entryPointTimeout = 1 -- 1s

-- | Load information that is required to complete transaction from
-- resource graph.
ruleGetEntryPoint :: Definitions RC ()
ruleGetEntryPoint = define "castor::cluster::entry-point-request" $ do
  main <- phaseHandle "main"
  loop <- phaseHandle "loop"
  setPhase main $ \(HAEvent uuid (GetSpielAddress fid profile pid)) -> do
    phaseLog "info" $ "Spiel Address requested."
    phaseLog "info" $ "requester.fid = " ++ show fid
    phaseLog "info" $ "requester.profile = " ++ show profile
    ep <- getSpielAddressRC
    case ep of
      Nothing -> do
        put Local $ Just (pid,0::Int)
        -- We process message here because in case of RC death,
        -- there will be timeout on the userside anyways.
        messageProcessed uuid
        continue (timeout entryPointTimeout loop)
      Just{} -> do
        logEP ep
        liftProcess $ usend pid ep
        messageProcessed uuid

  directly loop $ do
    Just (pid, _) <- get Local
    ep <- getSpielAddressRC
    case ep of
      Nothing -> do
        continue (timeout entryPointTimeout loop)
      Just{} -> do
        logEP ep
        liftProcess $ usend pid ep

  start main Nothing
  where
    logEP Nothing = Log.rcLog' Log.WARN "Entrypoint information not available."
    logEP (Just (M0.SpielAddress confd_fids confd_eps quorum rm_fid rm_ep)) =
      Log.rcLog' Log.DEBUG
        [ ("confd.fids"   , show confd_fids)
        , ("confd.eps"    , show confd_eps)
        , ("confd.quorum" , show quorum)
        , ("rm.fids"      , show rm_fid)
        , ("rm.ep"        , show rm_ep)
        ]

meroRules :: Definitions RC ()
meroRules = do

  define "Sync-to-confd" $ do
    initial <- phaseHandle "initial"
    reply   <- phaseHandle "reply"
    synchronize <- mkSyncAction _2 reply
    setPhase initial $ \(HAEvent eid afterSync) -> do
      put Local (eid, Nothing)
      synchronize afterSync
    directly reply $ do
      uuid <- fst <$> get Local
      messageProcessed uuid
      selfMessage (SyncComplete uuid)
    start initial (UUID.nil, Nothing)

  define "Sync-to-confd-local" $ do
    initial <- phaseHandle "initial"
    reply   <- phaseHandle "reply"
    synchronize <- mkSyncAction _2 reply
    setPhase initial $ \(uuid, afterSync) -> do
      put Local (uuid, Nothing)
      synchronize afterSync
    directly reply $ do
      uuid <- fst <$> get Local
      selfMessage (SyncComplete uuid)
    start initial (UUID.nil, Nothing)

  -- This rule answers to the notification interface when it wants to get the
  -- state of some configuration objects.
  defineSimpleTask "castor::cluster::state-get" $ \(Get client fids) -> do
    getLocalGraph >>= liftProcess . usend client .
      GetReply . map (uncurry Note) . lookupConfObjectStates fids

  -- Reply to the Failure vector request.
  defineSimpleTask "mero::failure-vector-reply" $ \(GetFailureVector pool port) -> do
    rg <- getLocalGraph
    let mv = (\(M0.DiskFailureVector v) -> (\w -> Note (M0.fid w) (toConfObjState w (getState w rg))) <$> v)
           <$> G.connectedTo (M0.Pool pool) R.Has rg
    phaseLog "debug" $ "FailureVector="++show mv
    liftProcess $ sendChan port mv

  defineSimple "mero:service-started" $ \(ServiceStartedInternal _node (_::MeroConf) pid) -> do
    phaseLog "info" "request mero channel"
    phaseLog "service.pid" $ show pid
    liftProcess $ usend pid ServiceStateRequest

  ruleGetEntryPoint

  M.rules
