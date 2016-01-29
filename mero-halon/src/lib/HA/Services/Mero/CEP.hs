-- |
-- Copyright: (C) 2015 Seagate LLC
--

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE CPP                        #-}

module HA.Services.Mero.CEP
  ( meroRulesF
  , meroChannel
  , meroChannels
  ) where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Core
import HA.ResourceGraph
import HA.Resources
import HA.Service
import HA.Services.Mero.Types

import Control.Category ((>>>))

import Data.Maybe (isJust, listToMaybe)

import Network.CEP

import Prelude hiding (id)

registerChannel :: ( Resource (TypedChannel a)
                   , Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel a)
                   )
                => ServiceProcess MeroConf
                -> TypedChannel a
                -> PhaseM LoopState l ()
registerChannel sp chan = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering m0d channel."
    return $  newResource sp   >>>
              newResource chan >>>
              connectUniqueTo sp MeroChannel chan $ rg

meroChannel :: ( Resource (TypedChannel a)
               , Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel a)
               )
            => Graph
            -> ServiceProcess MeroConf
            -> Maybe (TypedChannel a)
meroChannel rg sp = listToMaybe [ chan | chan <- connectedTo sp MeroChannel rg ]

-- | Fetch all Mero notification channels.
meroChannels :: Service MeroConf -> Graph -> [TypedChannel NotificationMessage]
meroChannels m0d rg = [ chan | node <- connectedTo Cluster Has rg
                             , isJust $ runningService node m0d rg
                             , sp   <- connectedTo node Runs rg :: [ServiceProcess MeroConf]
                             , chan <- connectedTo sp MeroChannel rg ]

meroRulesF :: Service MeroConf -> Definitions LoopState ()
meroRulesF _ = do
  defineSimple "declare-mero-channel" $
    \(HAEvent eid (DeclareMeroChannel sp c cc) _) -> do
      registerChannel sp c
      registerChannel sp cc
      messageProcessed eid
