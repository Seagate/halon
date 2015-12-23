-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Actions.Mero.Failure
  ( Failures(..)
  , PoolVersion(..)
  , Strategy(..)
  , createPoolVersions
  ) where

import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import HA.RecoveryCoordinator.Actions.Mero.Core
import Mero.ConfC (Fid(..), PDClustAttr(..))

import Control.Category
import Control.Monad ((>=>))
import qualified Control.Monad.State.Lazy as S
import qualified Data.Set as Set
import Data.Foldable (forM_)
import Data.Word
import Data.Proxy (Proxy(..))
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

-- | Convert failure tolerance vector to a straight array of Words for
--   passing to Mero.
failuresToArray :: Failures -> [Word32]
failuresToArray f = [f_pool f, f_rack f, f_encl f, f_ctrl f, f_disk f]

-- |  Minimal representation of a pool version for generation.
data PoolVersion = PoolVersion !(Set.Set Fid) !Failures
                  -- ^ @PoolVersion fids fs@ where @fids@ is a set of
                  -- fids and @fs@ are allowable failures in each
                  -- failure domain.
  deriving (Eq, Ord, Show)


-- | Strategy for generating pool versions. There may be multiple
--   implementations corresponding to different strategies.
data Strategy = Strategy {

    -- | Initial set of pool versions created at the start of the system,
    --   or when the cluster configuration changes.
    onInit :: G.Graph
           -> Maybe (G.Graph) -- ^ Returns `Nothing` if the graph is unmodified,
                              --   else the updated graph.

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
      onInit = i1 >=> i2
    , onFailure = f1 >=> f2
  }

-- | Create specified pool versions in the resource graph.
createPoolVersions :: M0.Filesystem
                   -> [PoolVersion]
                   -> Bool -- If specified, the pool version is assumed to
                           -- contain failed devices, rather than working ones.
                   -> G.Graph
                   -> G.Graph
createPoolVersions fs pvers invert rg =
    S.execState (mapM_ createPoolVersion pvers) rg
  where
    pool = M0.Pool (M0.f_mdpool_fid fs)
    test failset x = (if invert then not else id) $ M0.fid x `Set.member` failset
    createPoolVersion :: PoolVersion -> S.State G.Graph ()
    createPoolVersion (PoolVersion failset failures) = do
      pver <- M0.PVer <$> S.state (newFid (Proxy :: Proxy M0.PVer))
                      <*> pure (failuresToArray failures)
                      <*> pure (PDClustAttr (error "number of disks")
                                            (error "global setting")
                                            (error "global setting")
                                            (error "unit size")
                                            (error "seed"))
      S.modify'
          $ G.newResource pver
        >>> G.connect pool M0.IsRealOf pver
      rg0 <- S.get
      forM_ (filter (test failset)
              $ G.connectedTo fs M0.IsParentOf rg0 :: [M0.Rack])
            $ \rack -> do
        rackv <- M0.RackV <$> S.state (newFid (Proxy :: Proxy M0.RackV))
        S.modify'
            $ G.newResource rackv
          >>> G.connect pver M0.IsParentOf rackv
          >>> G.connect rack M0.IsRealOf rackv
        rg1 <- S.get
        forM_ (filter (test failset)
                $ G.connectedTo rack M0.IsParentOf rg1 :: [M0.Enclosure])
              $ \encl -> do
          enclv <- M0.EnclosureV <$> S.state (newFid (Proxy :: Proxy M0.EnclosureV))
          S.modify'
              $ G.newResource enclv
            >>> G.connect rackv M0.IsParentOf enclv
            >>> G.connect encl M0.IsRealOf enclv
          rg2 <- S.get
          forM_ (filter (test failset)
                  $ G.connectedTo encl M0.IsParentOf rg2 :: [M0.Controller])
                $ \ctrl -> do
            ctrlv <- M0.ControllerV <$> S.state (newFid (Proxy :: Proxy M0.ControllerV))
            S.modify'
                $ G.newResource ctrlv
              >>> G.connect enclv M0.IsParentOf ctrlv
              >>> G.connect ctrl M0.IsRealOf ctrlv
            rg3 <- S.get
            forM_ (filter (test failset)
                    $ G.connectedTo ctrl M0.IsParentOf rg3 :: [M0.Disk])
                  $ \disk -> do
              diskv <- M0.DiskV <$> S.state (newFid (Proxy :: Proxy M0.DiskV))
              S.modify'
                  $ G.newResource diskv
                >>> G.connect ctrlv M0.IsParentOf diskv
                >>> G.connect disk M0.IsRealOf diskv
