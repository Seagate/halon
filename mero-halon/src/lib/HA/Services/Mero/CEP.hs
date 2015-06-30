-- |
-- Copyright: (C) 2015 Seagate LLC
--

{-# LANGUAGE OverloadedStrings          #-}

module HA.Services.Mero.CEP (meroRulesF) where

import HA.EventQueue.Consumer
import HA.RecoveryCoordinator.Mero
import HA.ResourceGraph
import HA.Resources
import HA.Resources.Mero
import HA.Resources.Mero.Note
import HA.Service
import HA.Services.Mero.Types

import Mero.Notification (Set(..))
import Mero.Notification.HAState

import Control.Category ((>>>))
import Control.Distributed.Process (sendChan)

import Data.Foldable (for_)
import Data.List (foldl')
import Data.Maybe (isJust)

import Network.CEP

import Prelude hiding (id)

registerChannel :: ServiceProcess MeroConf
                -> TypedChannel Set
                -> PhaseM LoopState ()
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
meroRulesF m0d = do
  defineHAEvent "declare-mero-channel" $
    \(HAEvent _ (DeclareMeroChannel sp c) _) -> do
      ph1 <- phase "state-1" $ do
        registerChannel sp c
      start ph1

  defineHAEvent "mero-set" $ \(HAEvent _ (Set nvec) _) -> do
    ph1 <- phase "state-1" $ do
      rg <- getLocalGraph
      let f rg1 (Note oid st) =
            let edges :: [Edge ConfObject Is ConfObjectState]
                edges = edgesFromSrc (ConfObject oid) rg
                    -- Disconnect object from any existing state and reconnect
                    -- it to a new one.
            in connect (ConfObject oid) Is st $
               foldr deleteEdge rg1 edges
          rg'      = foldl' f rg nvec

      for_ (meroChannels m0d rg') $ \(TypedChannel chan) -> do
        liftProcess $ sendChan chan (Set nvec)

    start ph1
