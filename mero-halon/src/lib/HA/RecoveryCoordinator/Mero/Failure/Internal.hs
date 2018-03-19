{-# LANGUAGE Rank2Types #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Failure.Internal
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.Failure.Internal
  ( Failures(..)
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
import           Data.Maybe (fromJust)
import qualified Data.Set as Set
import           Data.Traversable (for)
import           Data.Typeable
import           Data.Word
import           HA.RecoveryCoordinator.Mero.Actions.Core
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid(..), PDClustAttr(..))

-- | Failure tolerance vector.
--
-- For a given pool version, the failure tolerance vector reflects how
-- many objects in each level can be expected to fail whilst still
-- allowing objects in that pool version to be read.
--
-- For disks, then, note that this will equal the parameter K, where
-- (N,K,P) is the triple of data units, parity units, pool width for
-- the pool version.
--
-- For controllers, this should indicate the maximum number such that
-- no failure of that number of controllers can take out more than K
-- units.  We can put an upper bound on this by considering
-- floor((nr_encls)/(N+K)), though distributional issues may result
-- in a lower value.
data Failures = Failures {
    f_pool :: !Word32 -- XXX-MULTIPOOLS: s/pool/site/
  , f_rack :: !Word32
  , f_encl :: !Word32
  , f_ctrl :: !Word32
  , f_disk :: !Word32
} deriving (Eq, Ord, Show)

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

-- | Convert failure tolerance vector to a straight array of Words for
--   passing to Mero.
failuresToArray :: Failures -> [Word32]
failuresToArray f = [f_pool f, f_rack f, f_encl f, f_ctrl f, f_disk f]

-- | Description of how halon run update of the graph.
data UpdateType m
  = Monolithic (G.Graph -> m G.Graph)
    -- ^ Transaction can be done into single atomic step.
  | Iterative (G.Graph -> Maybe ((G.Graph -> m G.Graph) -> m G.Graph))
    -- ^ Transaction should be done iteratively. Function may return
    -- a graph synchronization function. If caller should provide a graph
    -- Returns all updates in chunks so caller can synchronize and stream
    -- graph updates in chunks of reasonable size.

-- | Create pool versions for the given pool.
createPoolVersionsInPool :: M0.Pool
                         -> [PoolVersion]
                         -> Bool -- ^ If specified, the pool version
                                 -- is assumed to contain failed devices,
                                 -- rather than working ones.
                         -> G.Graph
                         -> G.Graph
createPoolVersionsInPool pool pvers invert =
    let mk = createPoolVersion pool invert
    in S.execState (mapM_ mk pvers)

createPoolVersion :: M0.Pool
                  -> Bool
                  -> PoolVersion
                  -> S.State G.Graph ()
createPoolVersion pool invert (PoolVersion mfid fids failures attrs) = do
    rg <- S.get
    let fids_drv = Set.filter (M0.fidIsType (Proxy :: Proxy M0.Disk)) fids
        width = if invert
                then totalDrives rg - Set.size fids_drv -- TODO: check this
                else Set.size fids_drv
    S.when (width > 0) $ do
        pver <- M0.PVer <$> (case mfid of
                                Just fid -> pure fid
                                Nothing -> S.state (newFid (Proxy :: Proxy M0.PVer))
                            )
                        <*> pure (M0.PVerActual (failuresToArray failures)
                                                (attrs { _pa_P = fromIntegral width }))
        runPVer pver
  where
    totalDrives rg = length
      [ disk
      -- XXX-MULTIPOOLS: site
      | let Just root = G.connectedTo Cluster Has rg :: Maybe M0.Root
      , rack :: M0.Rack <- G.connectedTo root M0.IsParentOf rg
      , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
      , ctrl :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
      , disk :: M0.Disk <- G.connectedTo ctrl M0.IsParentOf rg
      ]

    filterByFids :: M0.ConfObj a => [a] -> [a]
    filterByFids =
        let check = if invert then Set.notMember else Set.member
        in filter $ \x -> check (M0.fid x) fids

    runPVer :: M0.PVer -> S.State G.Graph ()
    runPVer pver = do
        rg <- S.get
        S.modify' $ G.connect pool M0.IsParentOf pver
        -- An element of list `vs` is True iff diskv objects were added to
        -- the corresponding subtree.
        let Just root = G.connectedTo Cluster Has rg :: Maybe M0.Root
        vs <- for (filterByFids
                   $ G.connectedTo root M0.IsParentOf rg :: [M0.Rack])
                  (runRack pver)
        unless (or vs) $ S.put rg

    runRack :: M0.PVer -> M0.Rack -> S.State G.Graph Bool
    runRack pver rack = do
        rackv <- M0.RackV <$> S.state (newFid (Proxy :: Proxy M0.RackV))
        rg <- S.get
        -- XXX-MULTIPOOLS: pver should be connected to sitev, not rackv
        S.modify' $ G.connect pver M0.IsParentOf rackv
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
createPoolVersions :: M0.Filesystem -- XXX-MULTIPOOLS
                   -> [PoolVersion]
                   -> Bool -- If specified, the pool version is assumed to
                           -- contain failed devices, rather than working ones.
                   -> G.Graph
                   -> G.Graph
createPoolVersions fs pvers invert rg =
    foldl' (\g p -> createPoolVersionsInPool p pvers invert g) rg pools
  where
    root = fromJust (G.connectedTo Cluster Has rg :: Maybe M0.Root)
    mdpool = M0.Pool (M0.rt_mdpool root)
    imeta_pools =
      [ pool
      | Just (pver :: M0.PVer) <-
            [M0.lookupConfObjByFid (M0.rt_imeta_pver root) rg]
      , Just (pool :: M0.Pool) <- [G.connectedFrom M0.IsParentOf pver rg]
      ]
    pools = filter (/= mdpool)
          . filter (\x -> not $ elem x imeta_pools)
          $ G.connectedTo fs M0.IsParentOf rg
