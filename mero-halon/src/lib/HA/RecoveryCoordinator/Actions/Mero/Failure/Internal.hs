-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE Rank2Types #-}
module HA.RecoveryCoordinator.Actions.Mero.Failure.Internal
  ( Strategy(..)
  , Failures(..)
  , PoolVersion(..)
  , failuresToArray
  , createPoolVersions
  , createPoolVersionsInPool
  ) where

import HA.RecoveryCoordinator.Actions.Mero.Core
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import Mero.ConfC (Fid(..), PDClustAttr(..))

import Control.Category
import Control.Monad ((>=>))
import qualified Control.Monad.State.Lazy as S
import           Data.Set (Set)
import qualified Data.Set as Set
import Data.Foldable (forM_)
import Data.List (foldl')
import Data.Word
import Data.Typeable
import Prelude hiding (id, (.))

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
data PoolVersion = PoolVersion !(Set Fid) !Failures !PDClustAttr
                  -- ^ @PoolVersion fids fs attrs@ where @fids@ is a set of
                  -- fids, @fs@ are allowable failures in each
                  -- failure domain, and @attrs@ are the parity declustering
                  -- attributes. Note that the value for @_pa_P@ will be
                  -- overridden with the width of the pool.
  deriving (Eq, Show)

-- | Convert failure tolerance vector to a straight array of Words for
--   passing to Mero.
failuresToArray :: Failures -> [Word32]
failuresToArray f = [f_pool f, f_rack f, f_encl f, f_ctrl f, f_disk f]

-- | Strategy for generating pool versions. There may be multiple
--   implementations corresponding to different strategies.
data Strategy = Strategy {

    -- | Initial set of pool versions created at the start of the system,
    --   or when the cluster configuration changes. Returns all updates
    --   in chunks so caller can synchronize and stream graph updates
    --   in chunks of reasonable size.
    onInit :: forall m . Monad m => G.Graph
           -> Maybe ((G.Graph -> m G.Graph) -> m G.Graph)

    -- | Action to take on failure
  , onFailure :: G.Graph
              -> Maybe (G.Graph) -- ^ Returns `Nothing` if the graph is
                                 --   unmodified, else the updated graph.)
}

-- | Allow combining strategies.
--   The 'empty' strategy generates no pool versions.
--   Combining strategies will generate pool versions when either strategy
--   generates them.
instance Monoid Strategy where
  mempty = Strategy { onInit = const Nothing, onFailure = const Nothing }
  (Strategy i1 f1) `mappend` (Strategy i2 f2) = Strategy {
      onInit = \g -> case i1 g of
                       Nothing -> i2 g
                       Just l  -> Just $ \u -> do g' <- l u
                                                  maybe (return g') ($u) (i2 g')

    , onFailure = f1 >=> f2
  }


createPoolVersionsInPool :: M0.Filesystem
                         -> M0.Pool
                         -> [PoolVersion]
                         -> Bool -- If specified, the pool version is assumed to
                                 -- contain failed devices, rather than working ones.
                         -> G.Graph
                         -> G.Graph
createPoolVersionsInPool fs pool pvers invert rg =
    S.execState (mapM_ createPoolVersion pvers) rg
  where
    test fids x = (if invert then Set.notMember else Set.member) (M0.fid x) fids
    totalDrives = length
       [ disk | rack :: M0.Rack <- G.connectedTo fs M0.IsParentOf rg
              , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
              , cntr :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
              , disk :: M0.Disk <- G.connectedTo cntr M0.IsParentOf rg
              ]

    createPoolVersion :: PoolVersion -> S.State G.Graph ()
    createPoolVersion (PoolVersion fids failures attrs) = do
      let
        fids_drv = Set.filter (M0.fidIsType (Proxy :: Proxy M0.Disk)) fids
        width = if invert
                then totalDrives - Set.size fids_drv -- TODO: check this
                else Set.size fids_drv
      S.when (width > 0) $ do
        pver <- M0.PVer <$> S.state (newFid (Proxy :: Proxy M0.PVer))
                        <*> pure (failuresToArray failures)
                        <*> pure (attrs { _pa_P = fromIntegral width })
        S.modify'
            $ G.newResource pver
          >>> G.connect pool M0.IsRealOf pver
        rg0 <- S.get
        forM_ (filter (test fids)
                $ G.connectedTo fs M0.IsParentOf rg0 :: [M0.Rack])
              $ \rack -> do
          rackv <- M0.RackV <$> S.state (newFid (Proxy :: Proxy M0.RackV))
          S.modify'
              $ G.newResource rackv
            >>> G.connect pver M0.IsParentOf rackv
            >>> G.connect rack M0.IsRealOf rackv
          rg1 <- S.get
          forM_ (filter (test fids)
                  $ G.connectedTo rack M0.IsParentOf rg1 :: [M0.Enclosure])
                $ \encl -> do
            enclv <- M0.EnclosureV <$> S.state (newFid (Proxy :: Proxy M0.EnclosureV))
            S.modify'
                $ G.newResource enclv
              >>> G.connect rackv M0.IsParentOf enclv
              >>> G.connect encl M0.IsRealOf enclv
            rg2 <- S.get
            forM_ (filter (test fids)
                    $ G.connectedTo encl M0.IsParentOf rg2 :: [M0.Controller])
                  $ \ctrl -> do
              ctrlv <- M0.ControllerV <$> S.state (newFid (Proxy :: Proxy M0.ControllerV))
              S.modify'
                  $ G.newResource ctrlv
                >>> G.connect enclv M0.IsParentOf ctrlv
                >>> G.connect ctrl M0.IsRealOf ctrlv
              rg3 <- S.get
              forM_ (filter (test fids)
                      $ G.connectedTo ctrl M0.IsParentOf rg3 :: [M0.Disk])
                    $ \disk -> do
                diskv <- M0.DiskV <$> S.state (newFid (Proxy :: Proxy M0.DiskV))
                S.modify'
                    $ G.newResource diskv
                  >>> G.connect ctrlv M0.IsParentOf diskv
                  >>> G.connect disk M0.IsRealOf diskv

-- | Create specified pool versions in the resource graph.
createPoolVersions :: M0.Filesystem
                   -> [PoolVersion]
                   -> Bool -- If specified, the pool version is assumed to
                           -- contain failed devices, rather than working ones.
                   -> G.Graph
                   -> G.Graph
createPoolVersions fs pvers invert rg =
    foldl' (\g p -> createPoolVersionsInPool fs p pvers invert g) rg pools
  where
    mdpool = M0.Pool (M0.f_mdpool_fid fs)
    pools = filter (/= mdpool) $ G.connectedTo fs M0.IsParentOf rg
