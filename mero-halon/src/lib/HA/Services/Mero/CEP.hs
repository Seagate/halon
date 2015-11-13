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
  , meroChannels
  ) where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Core
import HA.ResourceGraph
import HA.Resources
import HA.Service
import HA.Services.Mero.Types

import Mero.Notification (Set(..))

import Control.Category ((>>>))

import Data.Maybe (isJust)

import Network.CEP

import Prelude hiding (id)

registerChannel :: ServiceProcess MeroConf
                -> TypedChannel Set
                -> PhaseM LoopState l ()
registerChannel sp chan = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering channel."
    return $  newResource sp   >>>
              removeOldChan sp >>>
              newResource chan >>>
              connect sp MeroChannel chan $ rg

removeOldChan :: ServiceProcess MeroConf -> Graph -> Graph
removeOldChan sp rg =
    case connectedTo sp MeroChannel rg :: [TypedChannel Set] of
      [c] -> disconnect sp MeroChannel c rg
      _   -> rg

meroChannels :: Service MeroConf -> Graph -> [TypedChannel Set]
meroChannels m0d rg = [ chan | node <- connectedTo Cluster Has rg
                             , isJust $ runningService node m0d rg
                             , sp   <- connectedTo node Runs rg :: [ServiceProcess MeroConf]
                             , chan <- connectedTo sp MeroChannel rg ]

meroRulesF :: Service MeroConf -> Definitions LoopState ()
meroRulesF _ = do
  defineSimple "declare-mero-channel" $
    \(HAEvent _ (DeclareMeroChannel sp c) _) -> do
      registerChannel sp c
