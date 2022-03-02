{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Rules and primitives specific to Mero

module HA.RecoveryCoordinator.Mero.Rules where

import           Control.Distributed.Process (usend, sendChan)
import           Control.Lens
import           Data.List (nub)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Mero.Events
import qualified HA.RecoveryCoordinator.Mero.Rules.Maintenance as M
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           Mero.ConfC (Fid)
import           Mero.Lnet (Endpoint, encodeEndpoint)
import           Mero.Notification (Get(..), GetReply(..))
import           Mero.Notification.HAState (Note(..))
import           Network.CEP
import           Prelude hiding (id)

-- | Time between entrypoint retries (seconds).
entryPointTimeout :: Int
entryPointTimeout = 1

-- | Given the fid of a 'M0.Process', return its endpoints.
endpointsOfProcess :: G.Graph -> Fid -> [Endpoint]
endpointsOfProcess rg fid =
  nub [ ep
      | Just (proc :: M0.Process) <- [M0.lookupConfObjByFid fid rg]
      , svc <- G.connectedTo proc M0.IsParentOf rg :: [M0.Service]
      , ep <- M0.s_endpoints svc
      ]

-- | Load information that is required to complete transaction from
-- resource graph.
ruleGetEntryPoint :: Definitions RC ()
ruleGetEntryPoint = define "castor::cluster::entry-point-request" $ do
  main <- phaseHandle "main"
  loop <- phaseHandle "loop"

  setPhase main $ \(HAEvent uuid (GetSpielAddress proc prof pid)) -> do
    rg <- getGraph
    let eps = T.unpack . encodeEndpoint <$> endpointsOfProcess rg proc
    Log.tagContext Log.SM [ ("requester.process", show proc)
                          , ("requester.profile", show prof)
                          , ("requester.endpoints", show eps)
                          ] Nothing
    Log.rcLog' Log.DEBUG $ "Spiel Address requested"
    ep <- getSpielAddressRC
    case ep of
      Nothing -> do
        put Local $ Just (pid, 0::Int)
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
    logEP (Just (M0.SpielAddress confd_fids confd_eps rm_fid rm_ep quorum)) =
      Log.rcLog' Log.DEBUG
        [ ("confd.fids"   , show confd_fids)
        , ("confd.eps"    , show confd_eps)
        , ("confd.quorum" , show quorum)
        , ("rm.fids"      , show rm_fid)
        , ("rm.ep"        , show rm_ep)
        ]

-- | Set of rules dealing with primitive mero operations.
meroRules :: Definitions RC ()
meroRules = do

  define "Sync-to-confd" $ do
    initial <- phaseHandle "initial"
    reply   <- phaseHandle "reply"
    synchronize <- mkSyncAction _2 reply
    setPhase initial $ \(HAEvent eid afterSync) -> do
      put Local (eid, defaultConfSyncState)
      Log.rcLog' Log.DEBUG $ show eid
      synchronize afterSync
    directly reply $ do
      uuid <- fst <$> get Local
      messageProcessed uuid
      selfMessage (SyncComplete uuid)
    start initial (UUID.nil, defaultConfSyncState)

  define "Sync-to-confd-local" $ do
    initial <- phaseHandle "initial"
    reply   <- phaseHandle "reply"
    synchronize <- mkSyncAction _2 reply
    setPhase initial $ \(uuid, afterSync) -> do
      put Local (uuid, defaultConfSyncState)
      Log.rcLog' Log.DEBUG $ show uuid
      synchronize afterSync
    directly reply $ do
      uuid <- fst <$> get Local
      selfMessage (SyncComplete uuid)
    start initial (UUID.nil, defaultConfSyncState)

  -- This rule answers to the notification interface when it wants to get the
  -- state of some configuration objects.
  defineSimpleTask "castor::cluster::state-get" $ \(Get client fids) -> do
    getGraph >>= liftProcess . usend client .
      GetReply . map (uncurry Note) . lookupConfObjectStates fids

  -- Reply to the Failure vector request.
  defineSimpleTask "mero::failure-vector-reply"
    $ \(GetFailureVector pool sp) -> do
        rg <- getGraph
        let mnotes :: Maybe [Note]
            mnotes = failVecToNotes <$> G.connectedTo (M0.Pool pool) Has rg

            failVecToNotes :: M0.DiskFailureVector -> [Note]
            failVecToNotes (M0.DiskFailureVector disks) =
                [ Note (M0.fid d) (toConfObjState d $ getState d rg)
                | d <- disks
                ]
        Log.rcLog' Log.DEBUG $ "pool=" ++ show pool
                            ++ " failvec=" ++ show mnotes
        liftProcess $ sendChan sp mnotes

  ruleGetEntryPoint

  M.rules
