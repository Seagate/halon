-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Mero.CEP (meroRulesF) where

import Data.Foldable (for_)

import Network.CEP

import HA.EventQueue.Consumer
import HA.RecoveryCoordinator.Mero
import HA.ResourceGraph
import HA.Resources
import HA.Services.Mero.Types
import Mero.Notification (Set(..))

registerChannel :: ServiceProcess MeroConf
                -> TypedChannel Set
                -> CEP LoopState ()
registerChannel sp chan = do
    ls <- get
    let rg' = newResource sp   >>>
              removeOldChan sp >>>
              newResource chan >>>
              connect sp MeroChannel chan $ lsGraph ls
    put ls { lsGraph = rg' }

removeOldChan :: ServiceProcess MeroConf -> Graph -> Graph
removeOldChan sp rg =
    case connectedTo sp MeroChannel :: [TypedChannel Set] of
      [c] -> disconnect sp MeroChannel c rg
      _   -> rg

meroChannels :: Service MeroConf -> Graph -> [TypedChannel Set]
meroChannels m0d rg = [ chan | node <- connectedTo Cluster Has rg
                             , isJust $ runningService node m0d rg
                             , sp   <- connectedTo node Runs rg
                             , chan <- connectedTo sp MeroChannel rg ]

meroRulesF :: Service MeroConf -> RuleM LoopState ()
meroRulesF m0d = do
    defineHAEvent "declare-mero-channel" id $
      \(HAEvent _ (DeclareMeroChannel sp c) _) ->
        registerChannel sp c

    defineHAEvent "mero-set" id $ \(HAEvent _ (Set nvec) _) -> do
      ls <- get
      let rg = lsGraph ls
          f rg1 (Note oid st) =
            let edges :: [G.Edge ConfObject Is ConfObjectState]
                edges = G.edgesFromSrc (ConfObject oid) rg
                    -- Disconnect object from any existing state and reconnect
                    -- it to a new one.
            in G.connect (ConfObject oid) Is st $
               foldr G.deleteEdge rg1 edges
          rg'      = foldl' f rg nvec

      for_ (meroChannels m0d rg') $ \n@(TypedChannel chan) -> do
        sendChan chan (Set nvec)
