{-# LANGUAGE Rank2Types #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Failure.Internal
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.Failure.Internal
  ( ConditionOfDevices(..)
  , PoolVersion(..)
  , UpdateType(..)
  , failuresToArray
  , createPoolVersions
  , createPoolVersionsInPool
  ) where

import           Control.Category hiding ((.))
import           Control.Monad (unless)
import qualified Control.Monad.State.Lazy as S
import           Data.Foldable (for_)
import           Data.List (foldl')
import qualified Data.Set as Set
import           Data.Traversable (for)
import           Data.Typeable
import           Data.Word
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid(..), PDClustAttr(..))

-- |  Minimal representation of a pool version for generation.
--
-- Note that the value for @_pa_P@ will be overridden with the width
-- of the pool.
data PoolVersion = PoolVersion
    !(Maybe Fid)   -- Pool version fid.
    !(Set.Set Fid) -- ^ Fids of hardware devices (racks, enclosures,
                   -- controllers, disks) that belong to this pool version.
    !Failures      -- ^ Allowable failures in each failure domain.
    !PDClustAttr   -- The parity declustering attributes.
  deriving (Eq, Show)

-- | Description of how halon run update of the graph.
data UpdateType m
  = Monolithic (G.Graph -> m G.Graph)
    -- ^ Transaction can be done into single atomic step.
  | Iterative (G.Graph -> Maybe ((G.Graph -> m G.Graph) -> m G.Graph))
    -- ^ Transaction should be done iteratively. Function may return
    -- a graph synchronization function. If caller should provide a graph
    -- Returns all updates in chunks so caller can synchronize and stream
    -- graph updates in chunks of reasonable size.
    --
    -- XXX DELETEME ?

data ConditionOfDevices = DevicesWorking | DevicesFailed
  deriving (Eq, Show)

-- | Create pool versions for the given pool.
createPoolVersionsInPool :: M0.Pool
                         -> [PoolVersion]
                         -> ConditionOfDevices
                         -> G.Graph
                         -> G.Graph
createPoolVersionsInPool pool pvers cond =
    S.execState $ mapM_ (createPoolVersion pool cond) pvers

failuresToArray :: Failures -> [Word32]
failuresToArray = error "XXX DELETEME"

createPoolVersion :: M0.Pool
                  -> ConditionOfDevices
                  -> PoolVersion
                  -> S.State G.Graph ()
createPoolVersion pool cond (PoolVersion mfid fids failures attrs) = do
    rg <- S.get
    let fids_drv = Set.filter (M0.fidIsType (Proxy :: Proxy M0.Disk)) fids
        width = case cond of
            DevicesWorking -> Set.size fids_drv
            DevicesFailed  -> totalDrives rg - Set.size fids_drv -- TODO: check this
    S.when (width > 0) $ do
        pver <- M0.PVer <$> (case mfid of
                                Just fid -> pure fid
                                Nothing -> S.state (newFid (Proxy :: Proxy M0.PVer))
                            )
                        <*> (pure . Right $
                             M0.PVerActual (attrs {_pa_P = fromIntegral width})
                                           (failuresToArray failures))
        runPVer pver
  where
    totalDrives rg = length
      [ disk
      | site :: M0.Site <- G.connectedTo (M0.getM0Root rg) M0.IsParentOf rg
      , rack :: M0.Rack <- G.connectedTo site M0.IsParentOf rg
      , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
      , ctrl :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
      , disk :: M0.Disk <- G.connectedTo ctrl M0.IsParentOf rg
      ]

    filterByFids :: M0.ConfObj a => [a] -> [a]
    filterByFids =
        let check = case cond of
                DevicesWorking -> Set.member
                DevicesFailed  -> Set.notMember
        in filter $ \x -> check (M0.fid x) fids

    runPVer :: M0.PVer -> S.State G.Graph ()
    runPVer pver = do
        rg <- S.get
        S.modify' $ G.connect pool M0.IsParentOf pver
        let root = M0.getM0Root rg
        -- An element of list `vs` is True iff diskv objects were added to
        -- the corresponding subtree.
        vs <- for (filterByFids
                   $ G.connectedTo root M0.IsParentOf rg :: [M0.Site])
                  (runSite pver)
        unless (or vs) $ S.put rg

    runSite :: M0.PVer -> M0.Site -> S.State G.Graph Bool
    runSite pver site = do
        sitev <- M0.SiteV <$> S.state (newFid (Proxy :: Proxy M0.SiteV))
        rg <- S.get
        S.modify' $ G.connect pver M0.IsParentOf sitev
                >>> G.connect site M0.IsRealOf sitev
        vs <- for (filterByFids
                   $ G.connectedTo site M0.IsParentOf rg :: [M0.Rack])
                  (runRack sitev)
        unless (or vs) $ S.put rg
        pure (or vs)

    runRack :: M0.SiteV -> M0.Rack -> S.State G.Graph Bool
    runRack sitev rack = do
        rackv <- M0.RackV <$> S.state (newFid (Proxy :: Proxy M0.RackV))
        rg <- S.get
        S.modify' $ G.connect sitev M0.IsParentOf rackv
                >>> G.connect rack M0.IsRealOf rackv
        vs <- for (filterByFids
                   $ G.connectedTo rack M0.IsParentOf rg :: [M0.Enclosure])
                  (runEncl rackv)
        unless (or vs) $ S.put rg
        pure (or vs)

    runEncl :: M0.RackV -> M0.Enclosure -> S.State G.Graph Bool
    runEncl rackv encl = do
        enclv <- M0.EnclosureV <$> S.state (newFid (Proxy :: Proxy M0.EnclosureV))
        rg <- S.get
        S.modify' $ G.connect rackv M0.IsParentOf enclv
                >>> G.connect encl M0.IsRealOf enclv
        vs <- for (filterByFids
                  $ G.connectedTo encl M0.IsParentOf rg :: [M0.Controller])
                  (runCtrl enclv)
        unless (or vs) $ S.put rg
        pure (or vs)

    runCtrl :: M0.EnclosureV -> M0.Controller -> S.State G.Graph Bool
    runCtrl enclv ctrl = do
        ctrlv <- M0.ControllerV <$> S.state (newFid (Proxy :: Proxy M0.ControllerV))
        rg <- S.get
        S.modify' $ G.connect enclv M0.IsParentOf ctrlv
                >>> G.connect ctrl M0.IsRealOf ctrlv
        let disks = filterByFids
                    $ G.connectedTo ctrl M0.IsParentOf rg :: [M0.Disk]
        for_ disks $ \disk -> do
            diskv <- M0.DiskV <$> S.state (newFid (Proxy :: Proxy M0.DiskV))
            S.modify' $ G.connect ctrlv M0.IsParentOf diskv
                    >>> G.connect disk M0.IsRealOf diskv
        pure (not $ null disks)

-- | Create specified pool versions in the resource graph. These will be
--   created inside all IO pools (e.g. not mdpool or imeta)
createPoolVersions :: [PoolVersion] -> ConditionOfDevices -> G.Graph -> G.Graph
createPoolVersions pvers cond rg =
    foldl' (\g p -> createPoolVersionsInPool p pvers cond g) rg pools
  where
    root = M0.getM0Root rg
    mdpool = M0.Pool (M0.rt_mdpool root)
    imeta_pools =
      [ pool
      | Just (pver :: M0.PVer) <-
            [M0.lookupConfObjByFid (M0.rt_imeta_pver root) rg]
      , Just (pool :: M0.Pool) <- [G.connectedFrom M0.IsParentOf pver rg]
      ]
    pools = filter (/= mdpool)
          . filter (\x -> not $ elem x imeta_pools)
          $ G.connectedTo root M0.IsParentOf rg
