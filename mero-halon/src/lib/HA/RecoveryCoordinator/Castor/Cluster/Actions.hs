{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Cluster.Actions
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
module HA.RecoveryCoordinator.Castor.Cluster.Actions
  ( -- * Guards
    barrierPass
    -- * Actions
  , notifyOnClusterTransition
  , calculateClusterLiveness
  ) where

import           Control.Distributed.Process (Process, usend)
import           Data.Either (isLeft)
import           Data.List (nub)
import           Data.Maybe (fromMaybe, isJust, listToMaybe)
import           Data.Monoid (All(..), Any(..))
import           Data.Traversable (for)
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.RecoveryCoordinator.Castor.Cluster.Events as Event
import qualified HA.RecoveryCoordinator.Castor.Pool.Actions as Pool
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import           HA.Resources.Castor (Is(..))
import           HA.Resources.Castor.Initial (Failures(..), failuresToList)
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.Notification (getSpielAddress)
import           Network.CEP (PhaseM)

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
  return $ if rightState state' then Just () else Nothing

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
  rg <- getGraph
  newRunLevel <- calculateRunLevel
  newStopLevel <- calculateStopLevel
  let disposition = fromMaybe M0.OFFLINE $ G.connectedTo Cluster Has rg
      oldState = getClusterStatus rg
      newState = M0.MeroClusterState disposition newRunLevel newStopLevel
  Log.actLog "Cluster transition" [ ("old state", show oldState)
                                  , ("new state", show newState) ]
  modifyGraph $ G.connect Cluster M0.StopLevel newStopLevel
              . G.connect Cluster M0.RunLevel newRunLevel
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
               | Just srv <- [G.connectedFrom Is M0.PrincipalRM rg :: Maybe M0.Service]
               ]
            )
        pools = Pool.getNonMD rg
    haveOngoingSNS <- fmap (getAll . mconcat) .
      for pools $ \pool -> getPoolRepairInformation pool >>= return . All . isJust

    havePVers <- do
      case mkFailuresSets of
        [] -> return True -- No errors here, unexpected fast path!!
        [Failures 0 0 0 0 0] -> return True
        ss -> fmap (getAny . mconcat) . for pools $ \pool -> do -- XXX-MULTIPOOLS: Do we need to check for sites here?
                return $ mconcat [ Any result
                                 | pver <- G.connectedTo pool M0.IsParentOf rg
                                 , let result = case M0.v_data pver of
                                         Right _  -> checkActual pver
                                         Left pvf ->
                                            any ((M0.vf_allowance pvf ==) . failuresToList) ss
                                 ]
    return $ Event.ClusterLiveness havePVers haveOngoingSNS haveQuorum havePrincipalRM
  where
    withTemporaryGraph action = do
      rg' <- getGraph
      modifyGraph $ const rg
      result <- action
      modifyGraph $ const rg'
      return result

    checkActual :: M0.PVer -> Bool
    checkActual pver | isLeft (M0.v_data pver) = error "Actual pver expected"
    checkActual pver = getAll $ mconcat
      [ mconcat $ All (deviceIsOK site rg) :
        [ mconcat $ All (deviceIsOK rack rg) :
          [ mconcat $ All (deviceIsOK encl rg) :
            [ mconcat $ All (ctrlIsOK ctrl rg) :
              [ All (diskIsOK disk rg)
              | diskv :: M0.DiskV <- G.connectedTo ctrlv M0.IsParentOf rg
              , Just (disk :: M0.Disk) <- [G.connectedFrom M0.IsRealOf diskv rg]
              ]
            | ctrlv :: M0.ControllerV <- G.connectedTo enclv M0.IsParentOf rg
            , Just (ctrl :: M0.Controller) <- [G.connectedFrom M0.IsRealOf ctrlv rg]
            ]
          | enclv :: M0.EnclosureV <- G.connectedTo rackv M0.IsParentOf rg
          , Just (encl :: M0.Enclosure) <- [G.connectedFrom M0.IsRealOf enclv rg]
          ]
        | rackv :: M0.RackV <- G.connectedTo sitev M0.IsParentOf rg
        , Just (rack :: M0.Rack) <- [G.connectedFrom M0.IsRealOf rackv rg]
        ]
      | sitev :: M0.SiteV <- G.connectedTo pver M0.IsParentOf rg
      , Just (site :: M0.Site) <- [G.connectedFrom M0.IsRealOf sitev rg]
      ]

    mkFailuresSets :: [Failures]
    mkFailuresSets = map getFailures $ mkPool
      [ mkSite site
        [ mkRack rack
          [ mkEncl encl
            [ mkCtrl ctrl
              [ mkDisk disk
              | disk :: M0.Disk <- G.connectedTo ctrl M0.IsParentOf rg
              ]
            | ctrl :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
            ]
          | encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
          ]
        | rack :: M0.Rack <- G.connectedTo site M0.IsParentOf rg
        ]
      | site :: M0.Site <- G.connectedTo (M0.getM0Root rg) M0.IsParentOf rg
      ]

    mkPool :: [[DeviceFailure]] -> [DeviceFailure]
    mkPool = (mconcat <$>) . sequenceA

    mkSite = mkLvl PVLSites
    mkRack = mkLvl PVLRacks
    mkEncl = mkLvl PVLEncls

    mkCtrl :: M0.Controller -> [DeviceFailure] -> [DeviceFailure]
    mkCtrl ctrl xs | ctrlIsOK ctrl rg = comb df xs
                   | otherwise        = [df]
      where
        df = dfLvl PVLCtrls

    mkDisk :: M0.Disk -> DeviceFailure
    mkDisk disk | diskIsOK disk rg = mempty
                | otherwise        = dfLvl PVLDisks

    comb :: (Eq a, Monoid a) => a -> [a] -> [a]
    comb x xs = let y = mconcat xs
                in if y == mempty then [mempty] else [x, y]

    mkLvl :: M0.HasConfObjectState a => PVerLvl -> a -> [[DeviceFailure]]
          -> [DeviceFailure]
    mkLvl lvl a xs
      | notElem lvl [PVLSites, PVLRacks, PVLEncls]
                        = error "mkLvl: Invalid argument"
      | deviceIsOK a rg = nub $ concat [ comb (dfLvl lvl) rs
                                       | rs <- sequenceA xs ]
      | otherwise       = [dfLvl lvl]

diskIsOK :: M0.Disk -> G.Graph -> Bool
diskIsOK disk rg = M0.getState disk rg `elem` [M0.SDSOnline, M0.SDSUnknown]

ctrlIsOK :: M0.Controller -> G.Graph -> Bool
ctrlIsOK ctrl rg = M0.getState ctrl rg /= M0.CSTransient

-- XXX There should be a generic way to implement 'deviceIsOK', which would
-- do the right thing in 'a ~ M0.Disk' and 'a ~ M0.Controller' cases.
deviceIsOK :: M0.HasConfObjectState a => a -> G.Graph -> Bool
deviceIsOK x rg = M0.getConfObjState x rg == M0.M0_NC_ONLINE

newtype DeviceFailure = DF { getFailures :: Failures }
  deriving Eq

instance Monoid DeviceFailure where
  mempty = DF (Failures 0 0 0 0 0)
  DF (Failures a0 a1 a2 a3 a4) `mappend` DF (Failures b0 b1 b2 b3 b4) =
    DF (Failures (a0+b0) (a1+b1) (a2+b2) (a3+b3) (a4+b4))

data PVerLvl =
    PVLSites
  | PVLRacks
  | PVLEncls
  | PVLCtrls
  | PVLDisks
  deriving Eq

dfLvl :: PVerLvl -> DeviceFailure
dfLvl PVLSites = DF $ (getFailures mempty){ f_site = 1 }
dfLvl PVLRacks = DF $ (getFailures mempty){ f_rack = 1 }
dfLvl PVLEncls = DF $ (getFailures mempty){ f_encl = 1 }
dfLvl PVLCtrls = DF $ (getFailures mempty){ f_ctrl = 1 }
dfLvl PVLDisks = DF $ (getFailures mempty){ f_disk = 1 }
