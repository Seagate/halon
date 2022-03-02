{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE StaticPointers   #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.State
-- Copyright : (C) 2016-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.Mero.State
  ( DeferredStateChanges(..)
  , applyStateChanges
  , createDeferredStateChanges
    -- * Re-export for convenience
  , AnyStateSet
  , stateSet
  ) where

import           HA.Encode (encodeP)
import           HA.RecoveryCoordinator.Castor.Drive.Internal
import           HA.RecoveryCoordinator.Mero.Events
import qualified HA.RecoveryCoordinator.Mero.Transitions as Transition
import           HA.RecoveryCoordinator.Mero.Transitions.Internal
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Services.Mero.RC

import           Mero.ConfC (ServiceType(..), Fid)
import           Mero.Notification (Set(..))
import           Mero.Notification.HAState (Note(..))

import           Control.Applicative (liftA2)
import           Control.Arrow (first)
import           Control.Category ((>>>))
import           Control.Distributed.Static (Static, staticApplyPtr)
import           Control.Monad (join, when, guard)

import           Data.Constraint (Dict)
import           Data.Either (lefts, partitionEithers)
import           Data.Foldable (for_)
import           Data.Function (fix)
import           Data.Functor (void)
import           Data.List (nub, genericLength)
import           Data.Maybe (catMaybes, maybeToList)
import           Data.Monoid
import qualified Data.Set as S
import           Data.Traversable (mapAccumL)
import           Data.Typeable
import           Data.Word
import           Text.Printf (printf)

import           Network.CEP

-- | A set of deferred state changes. Consists of a graph
--   update function, a `Set` event for Mero, and an
--   `InternalObjectStateChange` event to send internally.
data DeferredStateChanges =
  DeferredStateChanges
    (G.Graph -> G.Graph) -- Graph update function
    Set -- Mero notification to send
    InternalObjectStateChange -- Internal notification to send

instance Monoid DeferredStateChanges where
  mempty = DeferredStateChanges id (Set [] Nothing) mempty
  (DeferredStateChanges f (Set s _) i)
    `mappend` (DeferredStateChanges f' (Set s' _) i') =
      DeferredStateChanges (f >>> f') (Set (s ++ s') Nothing) (i <> i')

-- | Responsible for 'cascading' a single state set into a `DeferredStateChanges`
--   object. Thus this should be responsible for:
--   - Any failure implications (e.g. inhibited states)
--   - Creating pool versions etc. in the graph
--   - Syncing to confd if necessary.
cascadeStateChange :: AnyStateChange -- ^ Change we're cascading on
                   -> G.Graph -- ^ RG
                   -> S.Set Fid
                   -- ^ Fids for which results in cascades are throw
                   -- away for.
                   -> (G.Graph->G.Graph, [AnyStateChange])
cascadeStateChange asc rg topFids = go [asc] [asc] id
   where
    -- XXX: better structues for union and difference, should we nub on b?
    go :: [AnyStateChange] -- New changes. These will be evaluated for cascade
       -> [AnyStateChange] -- Accumulated changes.
       -> (G.Graph -> G.Graph) -- Accumulated graph updates.
       -> (G.Graph -> G.Graph, [AnyStateChange])
    go = fix $ \f new_cgs acc old_f ->
           if null new_cgs
           then (old_f, acc)
           else let (updates, bs) = unzip $ liftA2 unwrap new_cgs stateCascadeRules
                    new_f = foldl (>>>) old_f (catMaybes updates)
                    b = filter (flip all acc . notMatch) $ join bs
                in f b (b ++ acc) (new_f)
    notMatch (AnyStateChange (a :: a) _ _ _) (AnyStateChange (b::b) _ _ _) =
      M0.fid a /= M0.fid b
    unwrap (AnyStateChange a a_old a_new _) r = tryApplyCascadeRule (a, a_old, a_new) r
    -- XXX: keep states in map a -> AnyStateChange, so eqT will always be Refl
    tryApplyCascadeRule :: forall a . Typeable a
                        => (a, M0.StateCarrier a, M0.StateCarrier a)
                        -> AnyCascadeRule
                        -> (Maybe (G.Graph -> G.Graph), [AnyStateChange])
    tryApplyCascadeRule s (AnyCascadeRule (scr :: StateCascadeRule a' b)) =
      case eqT :: Maybe (a :~: a') of
        Just Refl ->
           fmap ((\(b, b_old, b_new) -> AnyStateChange b b_old b_new sp) <$>)
                (applyCascadeRule scr s)
          where
            sp = staticApplyPtr
                  (static M0.someHasConfObjectStateDict)
                  (M0.hasStateDict :: Static (Dict (M0.HasConfObjectState b)))
        Nothing -> (Nothing, [])
    applyCascadeRule :: ( M0.HasConfObjectState b)
                     => StateCascadeRule a b
                     -> (a, M0.StateCarrier a, M0.StateCarrier a)   -- state change
                     -> (Maybe (G.Graph -> G.Graph),[(b, M0.StateCarrier b, M0.StateCarrier b)]) -- new updated states
    applyCascadeRule (StateCascadeRule old new f u) (a, a_old, a_new) =
      if old a_old && new a_new
      then ( Nothing
           , [ (b, b_old, b_new)
             | b <- f a rg
             -- Throw away objects in cascade that have been set "at
             -- top level".
             , M0.fid b `S.notMember` topFids
             , let b_old = M0.getState b rg
             , TransitionTo b_new <- [runTransition (u a_new) b_old]
             ])
      else (Nothing, [])
    applyCascadeRule (StateCascadeTrigger old new fg) (a, a_old, a_new) =
      if old a_old && new a_new
      then (Just (fg a), [])
      else (Nothing, [])

-- | Create deferred state changes for a number of objects.
--
-- Should implicitly cascade all necessary changes under the covers.
-- Returns a list of warnings (if any) along with 'DeferredStateChanges'.
createDeferredStateChanges :: [AnyStateSet] -> G.Graph -> ([String], DeferredStateChanges)
createDeferredStateChanges stateSets rg =
    (wrns, DeferredStateChanges (fn>>>trigger_fn) (Set nvec Nothing) (InternalObjectStateChange iosc))
  where
    (trigger_fn, stateChanges) = join <$>
        mapAccumL (\fg change -> first ((>>>) fg) (cascadeStateChange change rg rootFids)) id rootStateChanges
    rootFids = S.fromList $ map (\(AnyStateChange o _ _ _) -> M0.fid o) rootStateChanges
    (wrns, rootStateChanges) = partitionEithers $ lookupOldState <$> stateSets
    lookupOldState (AnyStateSet (x :: a) t) = case runTransition t $ M0.getState x rg of
      NoTransition -> Left $
        printf "%s: no transition from %s" (M0.showFid x) (show $ M0.getState x rg)
      InvalidTransition mkErr -> Left $ mkErr x
      TransitionTo st -> Right $ AnyStateChange x (M0.getState x rg) st sp
      where
        sp = staticApplyPtr
              (static M0.someHasConfObjectStateDict)
              (M0.hasStateDict :: Static (Dict (M0.HasConfObjectState a)))
    (fn, nvec, iosc) = go (id, [], []) stateChanges
    go (f, nv, io) xs = case xs of
      [] -> (f, nv, io)
      (x@(AnyStateChange s _ s_new _):xs') -> go (f', nv', io') xs' where
        f' = f >>> M0.setState s s_new
        nv' = (Note (M0.fid s) (M0.toConfObjState s s_new)) : nv
        io' = x : io

-- | Apply a number of state changes.
applyStateChanges :: [AnyStateSet] -> PhaseM RC l [AnyStateChange]
applyStateChanges ss = do
  rg <- getGraph
  let (warns, changes) = createDeferredStateChanges ss rg
  for_ warns $ Log.rcLog' Log.WARN
  applyDeferredStateChanges changes
  let DeferredStateChanges _ _ (InternalObjectStateChange i) = changes
  return i

-- | Apply deferred state changes in the standard order.
applyDeferredStateChanges :: DeferredStateChanges -> PhaseM RC l ()
applyDeferredStateChanges (DeferredStateChanges f s i) = do
  diff <- mkStateDiff f (encodeP i) []
  notifyMeroAsync diff s
  let InternalObjectStateChange iosc = i
  for_ iosc $ \(AnyStateChange a o n _) -> do
    Log.sysLog' . Log.StateChange $ Log.StateChangeInfo {
      Log.lsc_entity = M0.showFid a
    , Log.lsc_oldState = show o
    , Log.lsc_newState = show n
    }

-- | Rule for cascading state changes
data StateCascadeRule a b where
  -- When the state of an object changes, update the state of other
  -- connected objects accordingly.
  StateCascadeRule :: (M0.HasConfObjectState a, M0.HasConfObjectState b)
                    => (M0.StateCarrier a -> Bool) --  Old state(s) if applicable
                    -> (M0.StateCarrier a -> Bool)  --  New state(s)
                    -> (a -> G.Graph -> [b]) --  Function to find new objects
                    -> Transition.CascadeTransition a b
                    -> StateCascadeRule a b
  -- Trigger an arbitrary graph update as a result of a state change.
  StateCascadeTrigger :: (M0.HasConfObjectState a, b ~ a)
                    => (M0.StateCarrier a -> Bool) --  Old state(s) if applicable
                    -> (M0.StateCarrier a -> Bool) --  New state(s)
                    -> (a -> G.Graph -> G.Graph) -- Update graph
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
  [ AnyCascadeRule siteCascadeRackRule
  , AnyCascadeRule rackCascadeEnclosureRule
  , AnyCascadeRule sdevCascadeDisk
  , AnyCascadeRule diskCascadeSdev
  , AnyCascadeRule nodeCascadeController
  , AnyCascadeRule diskFailsPVer
  , AnyCascadeRule diskFixesPVer
  , AnyCascadeRule diskAddToFailureVector
  , AnyCascadeRule diskRemoveFromFailureVector
  , AnyCascadeRule processCascadeServiceRule
  , AnyCascadeRule nodeFailsProcessRule
  , AnyCascadeRule nodeUnfailsProcessRule
  , AnyCascadeRule serviceCascadeDiskRule
  ] ++ (AnyCascadeRule <$> enclosureCascadeControllerRules)
    ++ (AnyCascadeRule <$> iosFailsController)

siteCascadeRackRule :: StateCascadeRule M0.Site M0.Rack
siteCascadeRackRule = StateCascadeRule
  (M0.M0_NC_ONLINE ==)
  (`elem` [M0.M0_NC_FAILED, M0.M0_NC_TRANSIENT])
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  Transition.siteCascadeRack

rackCascadeEnclosureRule :: StateCascadeRule M0.Rack M0.Enclosure
rackCascadeEnclosureRule = StateCascadeRule
  (M0.M0_NC_ONLINE ==)
  (`elem` [M0.M0_NC_FAILED, M0.M0_NC_TRANSIENT])
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  Transition.rackCascadeEnclosure   -- XXX: what if enclosure is failed (?)

enclosureCascadeControllerRules :: [StateCascadeRule M0.Enclosure M0.Controller]
enclosureCascadeControllerRules =
  [ StateCascadeRule
      (M0.M0_NC_ONLINE ==)
      (`elem` [M0.M0_NC_FAILED, M0.M0_NC_TRANSIENT])
      (\x rg -> G.connectedTo x M0.IsParentOf rg)
      Transition.enclosureCascadeControllerTransient
  , StateCascadeRule
      (M0.M0_NC_ONLINE /=)
      (M0.M0_NC_ONLINE ==)
      (\x rg -> G.connectedTo x M0.IsParentOf rg)
      Transition.enclosureCascadeControllerOnline
  ]

processCascadeServiceRule :: StateCascadeRule M0.Process M0.Service
processCascadeServiceRule = StateCascadeRule
    (const True)
    (const True)
    (\x rg -> G.connectedTo x M0.IsParentOf rg)
    Transition.processCascadeService

serviceCascadeDiskRule :: StateCascadeRule M0.Service M0.SDev
serviceCascadeDiskRule = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  Transition.serviceCascadeDisk

-- | This is a rule which interprets state change events and is responsible for
-- changing the state of the cluster accordingly'
nodeFailsProcessRule :: StateCascadeRule M0.Node M0.Process
nodeFailsProcessRule = StateCascadeRule
  (const True)
  (\x -> M0.NSFailed == x || M0.NSFailedUnrecoverable == x)
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  Transition.nodeFailsProcess

-- | When node becames online again, we should mark it as
nodeUnfailsProcessRule :: StateCascadeRule M0.Node M0.Process
nodeUnfailsProcessRule = StateCascadeRule
  (\x -> M0.NSFailed == x || M0.NSFailedUnrecoverable == x)
  (== M0.NSOnline)
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  Transition.nodeUnfailsProcess

-- This is a phantom rule; SDev state is queried through Disk state,
-- so this rule just exists to include the `SDev` in the set of
-- notifications which get sent out.
sdevCascadeDisk :: StateCascadeRule M0.SDev M0.Disk
sdevCascadeDisk = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> maybeToList $ G.connectedTo x M0.IsOnHardware rg)
  Transition.sdevCascadeDisk'

diskCascadeSdev :: StateCascadeRule M0.Disk M0.SDev
diskCascadeSdev = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> maybeToList $ G.connectedFrom M0.IsOnHardware x rg)
  Transition.diskCascadeSDev'

nodeCascadeController :: StateCascadeRule M0.Node M0.Controller
nodeCascadeController = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> maybeToList $ G.connectedTo x M0.IsOnHardware rg)
  Transition.nodeCascadeController'

-- | HALON-425
--   This is a temporary cascade rule. Normally, there should be no direct link
--   between service and controller, because there might be multiple Services
--   per controller. However, until Mero can appropriately escalate failures in
--   its pool version code, we elevate service failures to controller failures
--   in Halon.
iosFailsController :: [StateCascadeRule M0.Service M0.Controller]
iosFailsController = [
      StateCascadeRule
        (const True)
        serviceFailed
        (\x rg -> case M0.s_type x of
          CST_IOS -> iosToController rg x
          _ -> [])
        Transition.iosFailsControllerTransient
    , StateCascadeRule
        (const True)  -- XXX: this is workaround as halon sets IOS to unknown
                      -- in prior to cluster start. As a result this rule never
                      -- started upon a restart.
        (not . serviceFailed)
        (\x rg -> case M0.s_type x of
          CST_IOS ->  iosToController rg x
          _ -> [])
        Transition.iosFailsControllerOnline
    ]
  where
    serviceFailed M0.SSFailed = True
    serviceFailed (M0.SSInhibited _) = True
    serviceFailed (M0.SSOffline) = True
    serviceFailed _ = False
    iosToController rg x = maybeToList $ do
      (proc :: M0.Process) <- G.connectedFrom M0.IsParentOf x rg
      (node :: M0.Node) <- G.connectedFrom M0.IsParentOf proc rg
      G.connectedTo node M0.IsOnHardware rg

diskFailsPVer :: StateCascadeRule M0.Disk M0.PVer
diskFailsPVer = StateCascadeRule
  (const True)
  (M0.SDSFailed ==)
  (\x rg -> let pvers = nub $
                  do diskv <- G.connectedTo x M0.IsRealOf rg :: [M0.DiskV]
                     Just pver <- [ do
                       ctrlv :: M0.ControllerV <- G.connectedFrom M0.IsParentOf diskv rg
                       enclv :: M0.EnclosureV <- G.connectedFrom M0.IsParentOf ctrlv rg
                       rackv :: M0.RackV <- G.connectedFrom M0.IsParentOf enclv rg
                       sitev :: M0.SiteV <- G.connectedFrom M0.IsParentOf rackv rg
                       G.connectedFrom M0.IsParentOf sitev rg :: Maybe M0.PVer ]
                     guard (M0.M0_NC_FAILED /= M0.getConfObjState pver rg)
                     return pver
            in lefts $ map (checkBroken rg) pvers)
  Transition.diskFailsPVer
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg pver@(M0.PVer _ (Right pva)) = do
     let fsite:frack:fencl:fctrl:fdisk:[] = M0.va_tolerance pva
     sitevs :: [M0.SiteV]       <- check fsite [pver] (Proxy :: Proxy M0.Site)
     rackvs :: [M0.RackV]       <- check frack sitevs (Proxy :: Proxy M0.Rack)
     enclvs :: [M0.EnclosureV]  <- check fencl rackvs (Proxy :: Proxy M0.Enclosure)
     ctrlvs :: [M0.ControllerV] <- check fctrl enclvs (Proxy :: Proxy M0.Controller)
     void (check fdisk ctrlvs (Proxy :: Proxy M0.Disk) :: Either M0.PVer [M0.DiskV])
     where
       check :: forall a b c. ( G.Relation M0.IsParentOf a b
                              , G.Relation M0.IsRealOf c b
                              , M0.HasConfObjectState c
                              , G.CardinalityTo M0.IsParentOf a b ~ 'G.Unbounded
                              , G.CardinalityFrom M0.IsRealOf c b ~ 'G.AtMostOne
                              )
             => Word32 -> [a] -> Proxy c -> Either M0.PVer [b]
       check limit objects Proxy = do
         let next = (\o -> G.connectedTo o M0.IsParentOf rg :: [b]) =<< objects
             broken = genericLength
               [ realm
               | n <- next
               , Just (realm :: c) <- [G.connectedFrom M0.IsRealOf n rg]
               , M0.M0_NC_FAILED == M0.getConfObjState realm rg
               ]
         when (broken > limit) $ Left pver
         return next
   checkBroken _ _ = Right ()

-- XXX REFACTORME: 'diskFailsPVer' and 'diskFixesPVer' share lots of code.
diskFixesPVer :: StateCascadeRule M0.Disk M0.PVer
diskFixesPVer = StateCascadeRule
  (const True)
  (M0.SDSOnline ==)
  (\x rg -> let pvers = nub $
                  do diskv <- G.connectedTo x M0.IsRealOf rg :: [M0.DiskV]
                     Just pver <- [ do
                       ctrlv :: M0.ControllerV <- G.connectedFrom M0.IsParentOf diskv rg
                       enclv :: M0.EnclosureV <- G.connectedFrom M0.IsParentOf ctrlv rg
                       rackv :: M0.RackV <- G.connectedFrom M0.IsParentOf enclv rg
                       sitev :: M0.SiteV <- G.connectedFrom M0.IsParentOf rackv rg
                       G.connectedFrom M0.IsParentOf sitev rg :: Maybe M0.PVer ]
                     guard (M0.M0_NC_ONLINE /= M0.getConfObjState pver rg)
                     return pver
            in lefts $ map (checkBroken rg) pvers)
  Transition.diskFixesPVer
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg pver@(M0.PVer _ (Right pva)) = do
     let fsite:frack:fencl:fctrl:fdisk:[] = M0.va_tolerance pva
     sitevs :: [M0.SiteV]       <- check fsite [pver] (Proxy :: Proxy M0.Site)
     rackvs :: [M0.RackV]       <- check frack sitevs (Proxy :: Proxy M0.Rack)
     enclvs :: [M0.EnclosureV]  <- check fencl rackvs (Proxy :: Proxy M0.Enclosure)
     ctrlvs :: [M0.ControllerV] <- check fctrl enclvs (Proxy :: Proxy M0.Controller)
     void (check fdisk ctrlvs (Proxy :: Proxy M0.Disk) :: Either M0.PVer [M0.DiskV])
     where
       check :: forall a b c. ( G.Relation M0.IsParentOf a b
                              , G.Relation M0.IsRealOf c b
                              , M0.HasConfObjectState c
                              , G.CardinalityTo M0.IsParentOf a b ~ 'G.Unbounded
                              , G.CardinalityFrom M0.IsRealOf c b ~ 'G.AtMostOne
                              )
             => Word32 -> [a] -> Proxy c -> Either M0.PVer [b]
       check limit objects Proxy = do
         let next = (\o -> G.connectedTo o M0.IsParentOf rg :: [b]) =<< objects
             broken = genericLength
               [ realm
               | n <- next
               , Just (realm :: c) <- [G.connectedFrom M0.IsRealOf n rg]
               , M0.M0_NC_ONLINE == M0.getConfObjState realm rg
               ]
         when (broken <= limit) $ Left pver
         return next
   checkBroken _ _ = Right ()

-- | When disk is failing we need to add that disk to the 'DiskFailureVector'.
diskAddToFailureVector :: StateCascadeRule M0.Disk M0.Disk
diskAddToFailureVector = StateCascadeTrigger
  (const True)
  (M0.SDSFailed ==)
  rgRecordDiskFailure

-- | When disk becomes online we need to add that disk to the 'DiskFailureVector'.
diskRemoveFromFailureVector :: StateCascadeRule M0.Disk M0.Disk
diskRemoveFromFailureVector = StateCascadeTrigger
  (const True)
  (M0.SDSOnline ==)
  rgRecordDiskOnline
