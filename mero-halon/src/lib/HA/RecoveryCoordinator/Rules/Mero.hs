{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules and primitives specific to Mero

module HA.RecoveryCoordinator.Rules.Mero where

import HA.EventQueue.Types

import HA.ResourceGraph as G
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Events.Mero
import HA.RecoveryCoordinator.Events.Service
import qualified HA.RecoveryCoordinator.Mero.Rules.Maintenance as M
import HA.Resources.Mero.Note
import qualified HA.Resources.Mero as M0
import qualified HA.Resources        as R
import HA.Services.Mero
import Mero.Notification (Get(..), GetReply(..))
import Mero.Notification.HAState (Note(..))

import Control.Distributed.Process (usend, sendChan)

import Network.CEP

import Prelude hiding (id)


meroRules :: Definitions LoopState ()
meroRules = do
  defineSimple "Sync-to-confd" $ \(HAEvent eid afterSync _) -> do
    syncAction (Just eid) afterSync
    messageProcessed eid
  defineSimple "Sync-to-confd-local" $ \(uuid, afterSync) -> do
    syncAction Nothing afterSync
    selfMessage (SyncComplete uuid)

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

  M.rules
