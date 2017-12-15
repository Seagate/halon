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
import qualified Data.Set as Set
import           Data.Traversable (for)
import           Data.Typeable
import           Data.Word
import           HA.RecoveryCoordinator.Mero.Actions.Core
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid(..), PDClustAttr(..))

-- | Failure tolerance vector. For a given pool version, the failure
--   tolerance vector reflects how many objects in each level can be expected
--   to fail whilst still allowing objects in that pool version to be read. For
--   disks, then, note that this will equal the parameter K, where (N,K,P) is
--   the triple of data units, parity units, pool width for the pool version.
--   For controllers, this should indicate the maximum number number such that
--   no failure of that number of controllers can take out more than K units. We
--   can put an upper bound on this by considering floor((no encls)/(N+K)),
--   though distributional issues may result in a lower value.
data Failures = Failures {
    f_pool :: !Word32
  , f_rack :: !Word32
  , f_encl :: !Word32
  , f_ctrl :: !Word32
  , f_disk :: !Word32
} deriving (Eq, Ord, Show)

-- |  Minimal representation of a pool version for generation.
data PoolVersion = PoolVersion !(Maybe Fid) !(Set.Set Fid) !Failures !PDClustAttr
                  -- ^ @PoolVersion fid fids fs attrs@ where @fids@ is a set of
                  -- fids, @fs@ are allowable failures in each
                  -- failure domain, and @attrs@ are the parity declustering
                  -- attributes. Note that the value for @pa_P@ will be
                  -- overridden with the width of the pool.
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
createPoolVersionsInPool :: M0.Filesystem
                         -> M0.Pool_XXX3
                         -> [PoolVersion]
                         -> Bool -- ^ If specified, the pool version
                                 -- is assumed to contain failed
                                 -- devices, rather than working ones.
                         -> G.Graph
                         -> G.Graph
createPoolVersionsInPool fs pool pvers invert rg =
    S.execState (mapM_ createPoolVersion pvers) rg
  where
    test fids x = (if invert then Set.notMember else Set.member) (M0.fid x) fids
    totalDrives = length
      [ disk
      | rack :: M0.Rack <- G.connectedTo fs M0.IsParentOf rg
      , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
      , cntr :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
      , disk :: M0.Disk <- G.connectedTo cntr M0.IsParentOf rg
      ]

    createPoolVersion :: PoolVersion -> S.State G.Graph ()
    createPoolVersion (PoolVersion pverfid fids failures attrs) = do
      let
        fids_drv = Set.filter (M0.fidIsType (Proxy :: Proxy M0.Disk)) fids
        width = if invert
                then totalDrives - Set.size fids_drv -- TODO: check this
                else Set.size fids_drv
      S.when (width > 0) $ do
        pver <- M0.PVer <$> ( case pverfid of
                                Just fid -> pure fid
                                Nothing -> S.state (newFid (Proxy :: Proxy M0.PVer))
                            )
                        <*> pure (M0.PVerActual (failuresToArray failures)
                                                (attrs { pa_P = fromIntegral width }))
        rg0 <- S.get
        S.modify' $ G.connect pool M0.IsParentOf pver
        i <- for (filter (test fids)
                 $ G.connectedTo fs M0.IsParentOf rg0 :: [M0.Rack]) $ \rack -> do
               rackv <- M0.RackV <$> S.state (newFid (Proxy :: Proxy M0.RackV))
               rg1 <- S.get
               S.modify'
                   $ G.connect pver M0.IsParentOf rackv
                 >>> G.connect rack M0.IsRealOf rackv
               i <- for (filter (test fids)
                        $ G.connectedTo rack M0.IsParentOf rg1 :: [M0.Enclosure])
                        $ \encl -> do
                      enclv <- M0.EnclosureV <$> S.state (newFid (Proxy :: Proxy M0.EnclosureV))
                      rg2 <- S.get
                      S.modify'
                          $ G.connect rackv M0.IsParentOf enclv
                        >>> G.connect encl M0.IsRealOf enclv
                      i <- for (filter (test fids)
                               $ G.connectedTo encl M0.IsParentOf rg2 :: [M0.Controller])
                               $ \ctrl -> do
                             ctrlv <- M0.ControllerV <$> S.state (newFid (Proxy :: Proxy M0.ControllerV))
                             rg3 <- S.get
                             S.modify'
                                 $ G.connect enclv M0.IsParentOf ctrlv
                               >>> G.connect ctrl M0.IsRealOf ctrlv
                             let disks = filter (test fids) $
                                   G.connectedTo ctrl M0.IsParentOf rg3 :: [M0.Disk]
                             for_ disks $ \disk -> do
                               diskv <- M0.DiskV <$> S.state (newFid (Proxy :: Proxy M0.DiskV))
                               S.modify'
                                    $ G.connect ctrlv M0.IsParentOf diskv
                                  >>> G.connect disk M0.IsRealOf diskv
                             return (not $ null disks)
                      unless (or i) $ S.put rg2
                      return (or i)

               unless (or i) $ S.put rg1
               return (or i)

        unless (or i) $ S.put rg0

-- | Create specified pool versions in the resource graph. These will be
--   created inside all IO pools (e.g. not mdpool or imeta)
createPoolVersions :: M0.Filesystem
                   -> [PoolVersion]
                   -> Bool -- If specified, the pool version is assumed to
                           -- contain failed devices, rather than working ones.
                   -> G.Graph
                   -> G.Graph
createPoolVersions fs pvers invert rg =
    foldl' (\g p -> createPoolVersionsInPool fs p pvers invert g) rg pools
  where
    mdpool = M0.Pool_XXX3 (M0.f_mdpool_fid fs)
    imeta_pools =
      [ pool
      | Just (pver :: M0.PVer) <- [M0.lookupConfObjByFid (M0.f_imeta_fid fs) rg]
      , Just (pool :: M0.Pool_XXX3) <- [G.connectedFrom M0.IsParentOf pver rg]
      ]
    pools = filter (/= mdpool)
          . filter (\x -> not $ elem x imeta_pools)
          $ G.connectedTo fs M0.IsParentOf rg
