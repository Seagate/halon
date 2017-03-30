{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Cluster.Actions
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Castor.Cluster.Actions
  ( -- * Guards
    barrierPass
    -- *Actions
  , notifyOnClusterTransition
  , calculateClusterLiveness
  ) where

import           Control.Distributed.Process (Process, usend)
import           Data.List (nub)
import           Data.Maybe (fromMaybe, listToMaybe)
import           Data.Monoid (All(..), Any(..))
import           Data.Traversable (for)
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.RecoveryCoordinator.Castor.Cluster.Events as Event
import qualified HA.RecoveryCoordinator.Castor.Pool.Actions as Pool
import           HA.RecoveryCoordinator.Mero.Failure.Internal
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.Notification (getSpielAddress)
import           Network.CEP

-- | Message guard: Check if the barrier being passed is for the
-- correct level. This is used during 'ruleNewMeroServer' with the
-- actual 'MeroClusterState' message being emitted from
-- 'notifyOnClusterTransition'.
barrierPass :: (M0.MeroClusterState -> Bool)
            -> Event.ClusterStateChange
            -> g
            -> l
            -> Process (Maybe ())
barrierPass rightState (Event.ClusterStateChange _ state') _ _ =
  if rightState state' then return (Just ()) else return Nothing

-- | Send a notification when the cluster state transitions.
--
-- The user specifies the desired state for the cluster and a builder
-- for for a notification that is sent when the cluster enters that
-- state. This means we can block across nodes by waiting for such a
-- message.
--
-- Whether the cluster is in the new state is determined by
-- 'calculateMeroClusterStatus' which traverses the RG and checks the
-- current cluster status and status of the processes on the current
-- cluster boot level.
notifyOnClusterTransition :: PhaseM RC l ()
notifyOnClusterTransition = do
  rg <- getLocalGraph
  newRunLevel <- calculateRunLevel
  newStopLevel <- calculateStopLevel
  let disposition = fromMaybe M0.OFFLINE $ G.connectedTo R.Cluster R.Has rg
      oldState = getClusterStatus rg
      newState = M0.MeroClusterState disposition newRunLevel newStopLevel
  Log.actLog "Cluster transition" [ ("old state", show oldState)
                                  , ("new state", show newState) ]
  modifyGraph $ G.connect R.Cluster M0.StopLevel newStopLevel
              . G.connect R.Cluster M0.RunLevel newRunLevel
  registerSyncGraphCallback $ \self _ -> do
    usend self (Event.ClusterStateChange oldState newState)

-- | Calculate what livenes properties exits in the given graph,
-- this function doesn't introduce any changes to resource graph itself.
calculateClusterLiveness :: G.Graph -> PhaseM RC l Event.ClusterLiveness
calculateClusterLiveness rg = withTemporaryGraph $ do
    let (haveQuorum, havePrincipalRM) = case getSpielAddress False rg of
          Nothing -> (False, False)
          Just (M0.SpielAddress fs _ _ _ q) ->
            ( length fs > q
            , fromMaybe False $ listToMaybe
               [ M0.SSOnline == M0.getState srv rg
               | srv :: M0.Service <- G.connectedFrom R.Is M0.PrincipalRM rg
               ]
            )
        pools = Pool.getNonMD rg
    haveOngoingSNS <- fmap (getAll . mconcat) .
      for pools $ \pool -> getPoolRepairInformation pool >>= \case
        Nothing -> return $ All False
        Just _  -> return $ All True

    havePVers <- getFilesystem >>= \case
      Nothing -> return True
      Just fs -> do
       let x = mkFailuresSets fs
       case  x of
        [] -> return True -- No errors here, unexpected fast path!!
        [Failures 0 0 0 0 0] -> return True
        ss -> fmap (getAny . mconcat) . for pools $ \pool -> do
                let rs = G.connectedTo pool M0.IsRealOf rg
                return $ mconcat [Any result
                                 | r <- rs
                                 , let result = case r of
                                         (M0.PVer _ M0.PVerActual{}) -> checkActual r
                                         (M0.PVer _ M0.PVerFormulaic{v_allowance=z}) ->
                                            any ((z ==) . failuresToArray) ss
                                 ]
    return $ Event.ClusterLiveness havePVers haveOngoingSNS haveQuorum havePrincipalRM
  where
    withTemporaryGraph action = do
      rg' <- getLocalGraph
      modifyGraph $ const rg
      result <- action
      modifyGraph $ const rg'
      return result
    checkActual :: M0.PVer -> Bool
    checkActual m0pver = getAll $ mconcat
        [ mconcat $ (All rack_status):
           [ mconcat $ (All enc_status):
              [ mconcat $ (All controller_status):
                  [ All disk_status
                  | m0diskV :: M0.DiskV <- G.connectedTo m0controllerV M0.IsParentOf rg
                  , Just (m0disk :: M0.Disk) <- [G.connectedFrom M0.IsRealOf m0diskV rg]
                  , let disk_status = case M0.getState m0disk rg of
                          M0.SDSOnline -> True
                          M0.SDSUnknown -> True
                          _ -> False
                  ]
              | m0controllerV :: M0.ControllerV <- G.connectedTo m0enclosureV M0.IsParentOf rg
              , Just (m0controller :: M0.Controller)
                  <- [G.connectedFrom M0.IsRealOf m0controllerV rg]
              , let controller_status = case M0.getState m0controller rg of
                                          M0.CSTransient -> False
                                          _ -> True
              ]
           | m0enclosureV :: M0.EnclosureV <- G.connectedTo m0rackV M0.IsParentOf rg
           , Just (m0enclosure :: M0.Enclosure)
               <- [G.connectedFrom M0.IsRealOf m0enclosureV rg]
           , let enc_status = case M0.getState m0enclosure rg of
                                M0.M0_NC_ONLINE -> True
                                _ -> False
           ]
        | m0rackV :: M0.RackV <- G.connectedTo m0pver M0.IsParentOf rg
        , Just (m0rack :: M0.Rack)
             <- [G.connectedFrom M0.IsRealOf m0rackV rg]
        , let rack_status = case M0.getState m0rack rg of
                              M0.M0_NC_ONLINE -> True
                              _ -> False
        ]

    mkFailuresSets :: M0.Filesystem -> [Failures]
    mkFailuresSets filesystem = map getFailures $ mkPool M0.NoExplicitConfigState
      [ mkRack r_state
         [ mkEnclosure e_state
             [ mkController c_state
                [ mkDisk d_state
                | disk :: M0.Disk <- G.connectedTo cntr M0.IsParentOf rg
                , let d_state = M0.getState disk rg
                ]
             | cntr :: M0.Controller <- G.connectedTo enclosure M0.IsParentOf rg
             , let c_state = M0.getState cntr rg
             ]
         | enclosure :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
         , let e_state = M0.getState enclosure rg
         ]
      | rack :: M0.Rack <- G.connectedTo filesystem M0.IsParentOf rg
      , let r_state = M0.getState rack rg
      ] where
      mkDisk M0.SDSOnline  = mempty
      mkDisk M0.SDSUnknown = mempty
      mkDisk _             = DF (Failures 0 0 0 0 1)
      mkController M0.CSTransient  _  = [DF (Failures 0 0 0 1 0)]
      mkController _               xs = case mconcat xs of
        DF (Failures 0 0 0 0 0) -> [mempty]
        y -> [DF (Failures 0 0 0 1 0), y]
      mkEnclosure M0.M0_NC_ONLINE xs = nub $ concat
         [ case mconcat rs of
             DF (Failures 0 0 0 0 0) -> [mempty]
             y -> [DF (Failures 0 0 1 0 0), y]
         | rs <- sequence xs
         ]
      mkEnclosure _ _ = [DF (Failures 0 0 1 0 0)]
      mkRack M0.M0_NC_ONLINE xs = nub $ concat
         [ case mconcat (rs::[DeviceFailure]) of
             DF (Failures 0 0 0 0 0) -> [mempty]
             y -> [DF (Failures 0 1 0 0 0), y]
         | rs <- sequence xs
         ]
      mkRack _ _ = [DF (Failures 0 1 0 0 0)]
      mkPool M0.NoExplicitConfigState xs = mconcat <$> sequence xs

newtype DeviceFailure = DF { getFailures :: Failures } deriving (Eq)

instance Monoid DeviceFailure where
  mempty = DF (Failures 0 0 0 0 0)
  DF (Failures a0 a1 a2 a3 a4) `mappend` DF (Failures b0 b1 b2 b3 b4) =
    DF (Failures (a0+b0) (a1+b1) (a2+b2) (a3+b3) (a4+b4))
