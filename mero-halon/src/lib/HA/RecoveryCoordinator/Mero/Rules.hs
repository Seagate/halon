{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules and primitives specific to Mero

module HA.RecoveryCoordinator.Mero.Rules where

import           Control.Distributed.Process (usend, sendChan)
import           Control.Lens
import           Data.Maybe (listToMaybe)
import           Data.Proxy (Proxy(..))
import qualified Data.UUID as UUID
import           Data.Vinyl
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Mero.Events
import qualified HA.RecoveryCoordinator.Mero.Rules.Maintenance as M
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Service
  ( findRunningServiceOn
  , getInterface
  )
import           HA.Service.Interface
  ( sendSvc )
import           HA.Services.Mero (lookupM0d)
import           HA.Services.Mero.Types
  ( MeroFromSvc(DixInitialised)
  , ProcessControlMsg(DixInit)
  , MeroToSvc(ProcessMsg)
  )
import           Mero.Notification (Get(..), GetReply(..))
import           Mero.Notification.HAState (Note(..))
import           Network.CEP
import           Prelude hiding (id)

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
    Log.tagContext Log.SM [ ("requester.fid", show fid)
                          , ("requester.profile", show profile)
                          ] Nothing
    Log.rcLog' Log.DEBUG $ "Spiel Address requested."
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
    logEP (Just (M0.SpielAddress confd_fids confd_eps rm_fid rm_ep quorum)) =
      Log.rcLog' Log.DEBUG
        [ ("confd.fids"   , show confd_fids)
        , ("confd.eps"    , show confd_eps)
        , ("confd.quorum" , show quorum)
        , ("rm.fids"      , show rm_fid)
        , ("rm.ep"        , show rm_ep)
        ]

-- | Initialise DIX subsystem in Mero.
jobDixInit :: Job DixInitRequest DixInitResult
jobDixInit = Job "mero::dixInit"

-- | Inititalise the DIX system.
--   This is required before clients can access the K-V store. This is currently
--   only used by Clovis clients.
--   The DIX subsystem needs to be initialised only once; after that, this
--   rule will directly exit after checking that the system has already been
--   initialised.
--
--   Initialisation is performed by calling `m0dixinit`. This call may be made
--   on any node in the cluster.
ruleDixInit :: Definitions RC ()
ruleDixInit = mkJobRule jobDixInit args $ \(JobHandle getRequest finish) -> do
    req <- phaseHandle "req"
    rep <- phaseHandle "rep"
    norep <- phaseHandle "norep"

    directly req $ do
      DixInitRequest fs <- getRequest
      dixInitTimeout <- getHalonVar _hv_m0dixinit_timeout
      rg <- getLocalGraph
      let m0d = lookupM0d rg
          nodes = findRunningServiceOn
            [ node
            | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
            , node <- G.connectedTo host R.Runs rg :: [R.Node]
            ]
            m0d rg
      case listToMaybe nodes of
        Just node@(R.Node nid) ->
          if G.isConnected fs R.Is M0.DIXInitialised rg
          then do
            Log.rcLog' Log.DEBUG "DIX subsystem already initialised."
            modify Local $ rlens fldRep .~
              Field (Just $ DixInitSuccess fs)
          else Log.withLocalContext' $ do
            Log.tagLocalContext node Nothing
            Log.rcLog Log.DEBUG "Initialising DIX subsystem"
            sendSvc (getInterface m0d) nid
              . ProcessMsg $ DixInit (M0.f_imeta_fid fs)
            switch [ rep, timeout dixInitTimeout norep ]
        Nothing -> do
          modify Local $ rlens fldRep . rfield .~
            (Just $ DixInitFailure fs "Cannot find node to call m0dixinit.")
          continue finish

    setPhaseIf rep dixInitialised $
      \(uid, res) -> do
        todo uid
        DixInitRequest fs <- getRequest
        case res of
          Right () -> do
            Log.rcLog' Log.DEBUG "DIX subsystem initialised successfully."
            modifyGraph $ G.connect fs R.Is M0.DIXInitialised
            modify Local $ rlens fldRep .~
              Field (Just $ DixInitSuccess fs)
          Left err -> do
            Log.rcLog' Log.ERROR $ "DIX subsystem failed to initialise: " ++ err
            modify Local $ rlens fldRep .~
              Field (Just $ DixInitFailure fs err)
        done uid
        continue finish

    directly norep $ do
      DixInitRequest fs <- getRequest
      modify Local $ rlens fldRep .~
        Field (Just $ DixInitFailure fs "Timeout waiting for m0dixinit.")
      continue finish

    return $ \(DixInitRequest fs) -> return $ Right (DixInitSuccess fs, [req])

  where
    dixInitialised (HAEvent uid (DixInitialised res)) _ _ =
      return $ Just (uid, res)
    dixInitialised _ _ _ = return Nothing
    fldReq = Proxy :: Proxy '("request", Maybe DixInitRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe DixInitResult)
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldRep  =: Nothing

-- | Set of rules dealing with primitive mero operations.
meroRules :: Definitions RC ()
meroRules = do

  define "Sync-to-confd" $ do
    initial <- phaseHandle "initial"
    reply   <- phaseHandle "reply"
    synchronize <- mkSyncAction _2 reply
    setPhase initial $ \(HAEvent eid afterSync) -> do
      put Local (eid, defaultConfSyncState)
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
      synchronize afterSync
    directly reply $ do
      uuid <- fst <$> get Local
      selfMessage (SyncComplete uuid)
    start initial (UUID.nil, defaultConfSyncState)

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
    Log.rcLog' Log.DEBUG $ "FailureVector=" ++ show mv
    liftProcess $ sendChan port mv

  ruleGetEntryPoint
  ruleDixInit

  M.rules
