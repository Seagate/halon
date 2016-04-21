-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers      #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns        #-}
module HA.RecoveryCoordinator.Rules.Mero.Conf
  ( DeferredStateChanges(..)
  , applyStateChangesCreateFS
  , applyStateChangesSyncConfd
  , createDeferredStateChanges
  , genericApplyDeferredStateChanges
  , genericApplyStateChanges
    -- * Temporary functions
  , notifyDriveStateChange
  )  where

import HA.Encode (encodeP)
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Events.Mero
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Services.Mero (notifyMeroBlocking)

import Mero.Notification (Set(..))
import Mero.Notification.HAState (Note(..))

import Control.Applicative (liftA2)
import Control.Category ((>>>))
import Control.Distributed.Static (Static, staticApplyPtr)
import Control.Monad (join)
import Control.Monad.Fix (fix)

import Data.Binary
import Data.Constraint (Dict)
import Data.Foldable (forM_, traverse_)
import Data.Hashable
import Data.Monoid
import Data.Typeable
import Data.List ((\\), union)

import Network.CEP

-- | Notify ourselves about a state change of the 'M0.SDev'.
--
-- Internally, build a note 'Set' and pass it to all registered
-- stateChangeHandlers.
--
-- TODO Remove this function.
notifyDriveStateChange :: M0.SDev -> M0.ConfObjectState -> PhaseM LoopState l ()
notifyDriveStateChange m0sdev st = do
    applyStateChangesCreateFS [ stateSet m0sdev st ]
    stateChangeHandlers <- lsStateChangeHandlers <$> Network.CEP.get Global
    sequence_ $ ($ ns) <$> stateChangeHandlers
 where
   ns = Set [Note (M0.fid m0sdev) st]

-- | A set of deferred state changes. Consists of a graph
--   update function, a `Set` event for Mero, and an
--   `InternalObjectStateChange` event to send internally.
data DeferredStateChanges =
  DeferredStateChanges
    (G.Graph -> G.Graph) -- Graph update function
    Set -- Mero notification to send
    InternalObjectStateChange -- Internal notification to send

instance Monoid DeferredStateChanges where
  mempty = DeferredStateChanges id (Set []) mempty
  (DeferredStateChanges f (Set s) i)
    `mappend` (DeferredStateChanges f' (Set s') i') =
      DeferredStateChanges (f >>> f') (Set $ s ++ s') (i <> i')

-- | Responsible for 'cascading' a single state set into a `DeferredStateChanges`
--   object. Thus this should be responsible for:
--   - Any failure implications (e.g. inhibited states)
--   - Creating pool versions etc. in the graph
--   - Syncing to confd if necessary.
cascadeStateChange :: AnyStateChange -> G.Graph -> [AnyStateChange]
cascadeStateChange asc rg = go [asc] [asc]
   where
    -- XXX: better structues for union and difference, should we nub on b?
    go :: [AnyStateChange] -> [AnyStateChange] -> [AnyStateChange]
    go = fix $ \f a c ->
           if null a
           then c
           else let b = join $ liftA2 unwrap a stateCascadeRules
                in f (filter (flip all c . notMatch) b) (b ++ c)
    notMatch (AnyStateChange (a :: a) _ _ _) (AnyStateChange (b::b) _ _ _) = 
       case eqT :: Maybe (a :~: b) of
         Just Refl -> a /= b
         Nothing -> True 
    unwrap (AnyStateChange a a_old a_new _) r = tryApplyCascadeRule (a, a_old, a_new) r
    -- XXX: keep states in map a -> AnyStateChange, so eqT will always be Refl
    tryApplyCascadeRule :: forall a . Typeable a
                        => (a, M0.StateCarrier a, M0.StateCarrier a)
                        -> AnyCascadeRule
                        -> [AnyStateChange]
    tryApplyCascadeRule s (AnyCascadeRule (scr :: StateCascadeRule a' b)) =
      case eqT :: Maybe (a :~: a') of
        Just Refl ->
           (\(b, b_old, b_new) -> AnyStateChange b b_old b_new sp)
             <$> applyCascadeRule scr s 
          where
            sp = staticApplyPtr
                  (static M0.someHasConfObjectStateDict)
                  (M0.hasStateDict :: Static (Dict (M0.HasConfObjectState a)))
        Nothing -> []
    applyCascadeRule :: ( M0.HasConfObjectState a
                        , M0.HasConfObjectState b
                        )
                     => StateCascadeRule a b
                     -> (a, M0.StateCarrier a, M0.StateCarrier a)   -- state change
                     -> [(b, M0.StateCarrier b, M0.StateCarrier b)] -- new updated states
    applyCascadeRule
      (StateCascadeRule old new f u)
      (a, a_old, a_new) =
        if (null old || a_old `elem` old) && (null new || a_new `elem` new)
        then [ (b, b_old, b_new)
             | b <- f a rg
             , let b_old = M0.getState b rg
             , let b_new = u a_new b_old
             ]
        else []

-- | Create deferred state changes for a number of objects.
--   Should implicitly cascade all necessary changes under the covers.
createDeferredStateChanges :: [AnyStateSet] -> G.Graph -> DeferredStateChanges
createDeferredStateChanges stateSets rg =
    DeferredStateChanges fn (Set nvec) (InternalObjectStateChange iosc)
  where
    stateChanges = join $ (flip cascadeStateChange $ rg) <$> rootStateChanges
    rootStateChanges = lookupOldState <$> stateSets
    lookupOldState (AnyStateSet (x :: a) st) =
        AnyStateChange x (M0.getState x rg) st sp
      where
        sp = staticApplyPtr
              (static M0.someHasConfObjectStateDict)
              (M0.hasStateDict :: Static (Dict (M0.HasConfObjectState a)))
    (fn, nvec, iosc) = go (id, [], []) stateChanges
    go (f, nv, io) xs = case xs of
      [] -> (f, nv, io)
      (x@(AnyStateChange s s_old s_new _):xs') -> go (f', nv', io') xs' where
        f' = f >>> M0.setState s s_new
        nv' = (Note (M0.fid s) (M0.toConfObjState s s_new)) : nv
        io' = x : io

-- | Apply a number of state changes, executing an action between updating
--   the graph and sending notifications to Mero and internally.
genericApplyStateChanges :: [AnyStateSet]
                         -> PhaseM LoopState l a
                         -> PhaseM LoopState l a
genericApplyStateChanges ass act = getLocalGraph >>= \rg -> let
    dsc@(DeferredStateChanges _ n _) = createDeferredStateChanges ass rg
  in do
    phaseLog "state-change-set" (show n)
    genericApplyDeferredStateChanges dsc act

-- | Generic function to apply deferred state changes in the standard order.
--   The provided 'action' is executed between updating the graph and sending
--   both 'Set' and 'InternalObjectStateChange' messages.
--
--   For more flexibility, you can write your own apply method which takes
--   a `DeferredStateChanges` argument.
genericApplyDeferredStateChanges :: DeferredStateChanges
                                 -> PhaseM LoopState l a
                                 -> PhaseM LoopState l a
genericApplyDeferredStateChanges (DeferredStateChanges f s i) action = do
  modifyGraph f
  syncGraph (return ())
  res <- action
  _ <- notifyMeroBlocking s
  promulgateRC $ encodeP i
  return res

-- | Apply state changes and synchronise with confd.
applyStateChangesSyncConfd :: [AnyStateSet]
                           -> PhaseM LoopState l ()
applyStateChangesSyncConfd ass =
    genericApplyStateChanges ass act
  where
    act = syncAction Nothing M0.SyncToConfdServersInRG

-- | Apply state changes and create any dynamic failure sets if needed.
--   This also syncs to confd.
applyStateChangesCreateFS :: [AnyStateSet]
                          -> PhaseM LoopState l ()
applyStateChangesCreateFS ass =
    genericApplyStateChanges ass act
  where
    act = do
      sgraph <- getLocalGraph
      mstrategy <- getCurrentStrategy
      forM_ mstrategy $ \strategy ->
        forM_ (onFailure strategy sgraph) $ \graph' -> do
          putLocalGraph graph'
          syncAction Nothing M0.SyncToConfdServersInRG

-- | Rule for cascading state changes
data StateCascadeRule a b where
  StateCascadeRule :: (M0.HasConfObjectState a, M0.HasConfObjectState b)
                    => [M0.StateCarrier a] --  Old state(s) if applicable
                    -> [M0.StateCarrier a] --  New state(s)
                    -> (a -> G.Graph -> [b]) --  Function to find new objects
                    -> (M0.StateCarrier a -> M0.StateCarrier b -> M0.StateCarrier b)
                    -> StateCascadeRule a b
  deriving Typeable

-- | Existential wrapper for rules, we can make to make
-- heterogenus lits of the rules.
data AnyCascadeRule = forall a b.
                      ( M0.HasConfObjectState a
                      , M0.HasConfObjectState b
                      )
                    => AnyCascadeRule (StateCascadeRule a b)
  deriving Typeable

-- | List all possible cascading rules
stateCascadeRules :: [AnyCascadeRule]
stateCascadeRules =
  [ AnyCascadeRule rackCascadeRule
  , AnyCascadeRule enclosureCascadeRule
  , AnyCascadeRule sdevCascadeRule
  ]


rackCascadeRule :: StateCascadeRule M0.Rack M0.Enclosure
rackCascadeRule = StateCascadeRule
  [M0.M0_NC_ONLINE]
  [M0.M0_NC_FAILED, M0.M0_NC_TRANSIENT]
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  (const $ const M0.M0_NC_TRANSIENT)  -- XXX: what if enclosure if failed (?)

enclosureCascadeRule :: StateCascadeRule M0.Enclosure M0.Controller
enclosureCascadeRule = StateCascadeRule
  [M0.M0_NC_ONLINE]
  [M0.M0_NC_FAILED, M0.M0_NC_TRANSIENT]
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  (const $ const M0.M0_NC_TRANSIENT)

-- This is a phantom rule; SDev state is queried through Disk state,
-- so this rule just exists to include the `SDev` in the set of
-- notifications which get sent out.
sdevCascadeRule :: StateCascadeRule M0.SDev M0.Disk
sdevCascadeRule = StateCascadeRule
  []
  []
  (\x rg -> G.connectedTo x M0.IsOnHardware rg)
  (const)
