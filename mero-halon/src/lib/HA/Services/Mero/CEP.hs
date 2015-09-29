-- |
-- Copyright: (C) 2015 Seagate LLC
--

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE RankNTypes                 #-}

module HA.Services.Mero.CEP
  ( meroRulesF
  , meroChannels
  ) where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Mero (lookupConfObjByFid)
import HA.RecoveryCoordinator.Mero
import HA.ResourceGraph
import HA.Resources
import HA.Resources.Castor
import HA.Resources.Mero (SDev(..))
import HA.Service
import HA.Services.Mero.Types

import Mero.Notification (Set(..))
import Mero.Notification.HAState

import Control.Category ((>>>))
import Control.Distributed.Process

import Data.Foldable (for_)
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
meroRulesF m0d = do
  defineSimple "declare-mero-channel" $
    \(HAEvent _ (DeclareMeroChannel sp c) _) -> do
      registerChannel sp c

-- TODO at the moment we assume this is an SDev - needs to be revisited
-- when we get updates for things other than disks.
  defineSimple "mero-set" $ \(HAEvent _ (Set nvec) _) -> let
      setStatus (Note oid st) = do
        mco <- lookupConfObjByFid oid
        case (mco :: Maybe SDev) of
          Just co -> modifyLocalGraph
            $ return . connectUniqueFrom co Is st
          _ -> return ()
    in do
      mapM_ setStatus nvec
      rg <- getLocalGraph
      for_ (meroChannels m0d rg) $ \(TypedChannel chan) -> do
        liftProcess $ sendChan chan (Set nvec)
