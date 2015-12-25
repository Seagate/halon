{-# LANGUAGE CPP                        #-}
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

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Events.Mero
import HA.Resources.Mero.Note
import Mero.Notification (Get(..), GetReply(..))
import Mero.Notification.HAState (Note(..))

import Control.Distributed.Process (usend)

import Network.CEP

import Prelude hiding (id)


meroRules :: Definitions LoopState ()
meroRules = do
  defineSimple "Sync-to-confd" $ \(HAEvent eid sync _) -> do
    syncAction (Just eid) sync
    messageProcessed eid
  defineSimple "Sync-to-confd-local" $ \(uuid, sync) -> do
    syncAction Nothing sync
    selfMessage (SyncComplete uuid)

  -- This rule answers to the notification interface when it wants to get the
  -- state of some configuration objects.
  defineSimple "ha-state-get" $ \(HAEvent uuid (Get client fids) _) -> do
      getLocalGraph >>= liftProcess . usend client .
        GetReply . map (uncurry Note) . rgLookupConfObjectStates fids
      messageProcessed uuid
