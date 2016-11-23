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
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.State
  ( DeferredStateChanges(..)
  , applyStateChanges
  , applyStateChangesSyncConfd
    -- * Re-export for convenience
  , AnyStateSet
  , stateSet
    -- * Rule helpers
  , mkPhaseNotify
  , setPhaseNotified
  , setPhaseAllNotified
  , setPhaseAllNotifiedBy
  , setPhaseInternalNotification
  , setPhaseInternalNotificationWithState
  , ascPred
  , anyStateToAscPred
  )  where

import HA.Encode (decodeP, encodeP)
import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Castor.Drive.Internal
import HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import HA.RecoveryCoordinator.Mero.Actions.Spiel
import HA.RecoveryCoordinator.Mero.Events
import HA.RecoveryCoordinator.Mero.Transitions.Internal
import qualified HA.RecoveryCoordinator.Mero.Transitions as Transition
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Services.Mero.RC

import Mero.ConfC (ServiceType(..))
import Mero.Notification (Set(..))
import Mero.Notification.HAState (Note(..))

import Control.Applicative (liftA2)
import Control.Category ((>>>))
import Control.Distributed.Process (Process)
import Control.Arrow (first)
import Control.Distributed.Static (Static, staticApplyPtr)
import Control.Monad (join, when, guard)
import Control.Monad.Fix (fix)
import Control.Lens

import Data.Constraint (Dict)
import Data.Either (partitionEithers)
import Data.Foldable (for_)
import Data.Maybe (catMaybes, listToMaybe, mapMaybe, maybeToList)
import Data.Monoid
import Data.Traversable (mapAccumL)
import Data.Typeable
import Data.List (foldl', nub, genericLength)
import Data.Either (lefts)
import Data.Functor (void)
import Data.Word
import Data.UUID (UUID)

import Network.CEP

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
cascadeStateChange :: AnyStateChange -> G.Graph -> (G.Graph->G.Graph, [AnyStateChange])
cascadeStateChange asc rg = go [asc] [asc] id
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
    applyCascadeRule :: ( M0.HasConfObjectState a
                        , M0.HasConfObjectState b
                        )
                     => StateCascadeRule a b
                     -> (a, M0.StateCarrier a, M0.StateCarrier a)   -- state change
                     -> (Maybe (G.Graph -> G.Graph),[(b, M0.StateCarrier b, M0.StateCarrier b)]) -- new updated states
    applyCascadeRule (StateCascadeRule old new f u) (a, a_old, a_new) =
      if old a_old && new a_new
      then ( Nothing
           , [ (b, b_old, b_new)
             | b <- f a rg
             , let b_old = M0.getState b rg
             , TransitionTo b_new <- [runTransition (u a_new) b_old]
             -- We still want this because we don't always catch
             -- NoTransition for every case
             , b_old /= b_new
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
    (wrns, DeferredStateChanges (fn>>>trigger_fn) (Set nvec) (InternalObjectStateChange iosc))
  where
    (trigger_fn, stateChanges) = fmap join $
        mapAccumL (\fg change -> first ((>>>) fg) (cascadeStateChange change rg)) id rootStateChanges
    (wrns, rootStateChanges) = partitionEithers $ mapMaybe lookupOldState stateSets
    lookupOldState (AnyStateSet (x :: a) t) = case runTransition t $ M0.getState x rg of
      NoTransition -> Nothing
      InvalidTransition err -> Just $ Left err
      TransitionTo st -> Just . Right $ AnyStateChange x (M0.getState x rg) st sp
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

-- | Apply a number of state changes, executing an action between updating
--   the graph and sending notifications to Mero and internally.
genericApplyStateChanges :: [AnyStateSet]
                         -> PhaseM RC l a
                         -> PhaseM RC l a
genericApplyStateChanges ass act = getLocalGraph >>= \rg -> do
  let (warns, changes) = createDeferredStateChanges ass rg
  for_ warns $ phaseLog "warn"
  genericApplyDeferredStateChanges changes act

-- | Generic function to apply deferred state changes in the standard order.
--   The provided 'action' is executed between updating the graph and sending
--   both 'Set' and 'InternalObjectStateChange' messages. The provided Process
--   actions are called after sending notification to Mero, should this succeed
--   or fail respectively.
--
--   For more flexibility, you can write your own apply method which takes
--   a `DeferredStateChanges` argument.
genericApplyDeferredStateChanges :: DeferredStateChanges
                                 -> PhaseM RC l a -- ^ action
                                 -> PhaseM RC l a
genericApplyDeferredStateChanges (DeferredStateChanges f s i) action = do
  diff <- mkStateDiff f (encodeP i) []
  notifyMeroAsync diff s
  let (InternalObjectStateChange iosc) = i
  for_ iosc $ \(AnyStateChange a o n _) -> do
    Log.sysLog' . Log.StateChange $ Log.StateChangeInfo {
      Log.lsc_entity = M0.showFid a
    , Log.lsc_oldState = show o
    , Log.lsc_newState = show n
    }
  action


-- | Apply state changes and do nothing else.
applyStateChanges :: [AnyStateSet]
                  -> PhaseM RC l ()
applyStateChanges ass =
    genericApplyStateChanges ass (return ())

-- | Apply state changes and synchronise with confd.
applyStateChangesSyncConfd :: [AnyStateSet]
                           -> PhaseM RC l ()
applyStateChangesSyncConfd ass =
    genericApplyStateChanges ass act
  where
    act = syncAction Nothing M0.SyncToConfdServersInRG

-- | @'setPhaseNotified' handle change extract act@
--
-- Create a 'RuleM' with the given @handle@ that runs the given
-- callback @act@ when internal state change notification for @change@
-- is received: effectively inside this rule we know that we have
-- notified mero about the change. @extract@ is used as a view from
-- local rule state to the object we're interested in.
--
-- TODO: Do we need to handle UUID here?
setPhaseNotified :: forall app b l g.
                    ( Application app
                    , g ~ GlobalState app
                    , M0.HasConfObjectState b
                    , Typeable (M0.StateCarrier b))
                 => Jump PhaseHandle
                 -> (l -> Maybe (b, M0.StateCarrier b -> Bool))
                 -> ((b, M0.StateCarrier b) -> PhaseM app l ())
                 -> RuleM app l ()
setPhaseNotified handle extract act =
  setPhaseIf handle changeGuard act
  where
    changeGuard :: HAEvent InternalObjectStateChangeMsg
                -> g -> l -> Process (Maybe (b, M0.StateCarrier b))
    changeGuard (HAEvent _ msg) _ (extract -> Just (obj, p)) =
      liftProcess (decodeP msg) >>= \(InternalObjectStateChange iosc) -> do
        return $ listToMaybe . mapMaybe (getObjP obj p) $ iosc
    changeGuard _ _ _ = return Nothing

    getObjP obj p x = case x of
      AnyStateChange (a::z) _ n _ -> case eqT :: Maybe (z :~: b) of
        Just Refl | a == obj && p n -> Just (a,n)
        _ -> Nothing

-- | Helper for 'setPhaseAllNotified' and 'setPhaseAllNotifiedBy'.
--
-- TODO: We should allow the user to pass in extra phases for timeout. Consider
--
-- @switch [all_notified, timeout t timed_out]@
--
-- If *any* 'InternalObjectStateChange' flies by before the timeout,
-- we won't be done, we'll 'continue' too @all_notified@ and the
-- timeout is effectively ignored.
mkPhaseAllNotified :: forall a l g. Application g
                   => (a -> AnyStateChange -> Bool)
                   -> Jump PhaseHandle
                   -> (Lens' l (Maybe [a]))
                   -> PhaseM g l () -- ^ Callback when set has been notified
                   -> RuleM g l ()
mkPhaseAllNotified toPred handle extract act =
  setPhase handle $ \(HAEvent _ msg) -> do
     mn <- gets Local (^. extract)
     case mn of
       Nothing -> do phaseLog "error" "Internal notifications are not set."
                     act
       Just notificationSet -> do
         InternalObjectStateChange iosc <- liftProcess $ decodeP (msg :: InternalObjectStateChangeMsg)
         -- O(n*(max(n, m))) i.e. at least O(n²) but possibly worse
         -- n = length notificationSet
         -- m = length iosc
         let next = foldl' (\sts asc -> filter (\s -> not $ toPred s asc) sts)
                           notificationSet iosc
         modify Local $ set extract (Just next)
         case next of
           [] -> act
           -- We're not done, re-run phase waiting for another state
           -- change message.
           _  -> continue handle

-- | For the given 'AnyStateSet', wait until every corresponding
-- 'InternalObjectStateChange' has been seen. If you want to accept a
-- wider range of messages than the ones directly specified by
-- 'AnyStateSet', use 'setPhaseAllNotifiedBy' instead.
--
-- Works across multiple separate notifications, until the set of
-- messages we are waiting for is empty.
setPhaseAllNotified :: forall l g. Application g
                    => Jump PhaseHandle
                    -> (Lens' l (Maybe [AnyStateSet]))
                    -> PhaseM g l () -- ^ Callback when set has been notified
                    -> RuleM g l ()
setPhaseAllNotified = mkPhaseAllNotified anyStateToAscPred

-- | As 'setPhaseAllNotified' but works on predicates on
-- 'AnyStateChange's. This allows finer control over what messages we
-- want to accept.
setPhaseAllNotifiedBy :: forall l g. Application g
                      => Jump PhaseHandle
                      -> (Lens' l (Maybe [AnyStateChange -> Bool]))
                      -> PhaseM g l () -- ^ Callback when set has been notified
                      -> RuleM g l ()
setPhaseAllNotifiedBy = mkPhaseAllNotified id

-- | Create a predicate on 'AnyStateChange' from an object and its
-- state. Useful for 'setPhaseAllNotifiedBy'.
ascPred :: M0.HasConfObjectState a => a -> (M0.StateCarrier a -> Bool)
        -> AnyStateChange -> Bool
ascPred (obj :: a) p (AnyStateChange obj' _ n _) = case (cast obj', cast n) of
  (Just obj'', Just n') -> obj == obj'' && p n'
  _ -> False

-- | Check that the 'AnyStateChange' directly corresponds to
-- 'Transition' encoded in the 'AnyStateSet'.
anyStateToAscPred :: AnyStateSet -> AnyStateChange -> Bool
anyStateToAscPred (AnyStateSet a tr) (AnyStateChange (obj :: objT) o n _) =
  case (cast a, cast tr) of
    (Just (a' :: objT), Just (tr' :: Transition objT)) ->
      obj == a' && case runTransition tr' o of
        TransitionTo n' -> n == n'
        _ -> False
    _ -> False

-- | As 'setPhaseInternalNotificationWithState', accepting all object states.
setPhaseInternalNotification :: forall b l app.
                                (Application app
                                , M0.HasConfObjectState b
                                , Typeable (M0.StateCarrier b))
                                => Jump PhaseHandle
                                -> ((UUID, [(b, M0.StateCarrier b)]) -> PhaseM app l ())
                                -> RuleM app l ()
setPhaseInternalNotification handle act =
  setPhaseInternalNotificationWithState handle (const $ const True) act

-- | Given a predicate on object state, retrieve all objects and
-- states satisfying the predicate from the internal state change
-- notification.
setPhaseInternalNotificationWithState :: forall app b l g.
                                      ( Application app
                                      , g ~ GlobalState app
                                      , M0.HasConfObjectState b
                                      , Typeable (M0.StateCarrier b))
                                      => Jump PhaseHandle
                                      -> (M0.StateCarrier b -> M0.StateCarrier b -> Bool)
                                      -> ((UUID, [(b, M0.StateCarrier b)]) -> PhaseM app l ())
                                      -> RuleM app l ()
setPhaseInternalNotificationWithState handle p act = setPhaseIf handle changeGuard act
  where
    changeGuard :: HAEvent InternalObjectStateChangeMsg
                -> g -> l -> Process (Maybe (UUID, [(b, M0.StateCarrier b)]))
    changeGuard (HAEvent eid msg) _ _ =
      (liftProcess . decodeP $ msg) >>= \(InternalObjectStateChange iosc) ->
        case mapMaybe getObjP iosc of
          [] -> return Nothing
          objs -> return $ Just (eid, objs)

    getObjP x = case x of
      AnyStateChange (a::z) o n _ -> case eqT :: Maybe (z :~: b) of
        Just Refl | p o n -> Just (a,n)
        _ -> Nothing

-- | Notify mero about the given object and wait for the arrival on
-- notification, handling failure.
mkPhaseNotify :: (Eq (M0.StateCarrier b), M0.HasConfObjectState b, Typeable (M0.StateCarrier b))
              => Int -- ^ timeout
              -> (l -> Maybe (b, M0.StateCarrier b)) -- ^ state getter
              -> PhaseM RC l [Jump PhaseHandle] -- ^ on failure
              -> (b -> M0.StateCarrier b -> PhaseM RC l [Jump PhaseHandle]) -- ^ on success
              -> RuleM RC l (b -> Transition b -> PhaseM RC l [Jump PhaseHandle])
mkPhaseNotify t getter onFailure onSuccess = do
  notify_done <- phaseHandle "Notification done"
  notify_timed_out <- phaseHandle "Notification timed out"

  let getterP l = fmap (fmap (==)) (getter l)

  setPhaseNotified notify_done getterP $ \(o, oSt) -> onSuccess o oSt >>= switch
  directly notify_timed_out $ onFailure >>= switch

  return $ \obj tr -> do
    rg <- getLocalGraph
    let currentSt = M0.getState obj rg
    case runTransition tr currentSt of
      NoTransition -> do
        phaseLog "info" "Object already in desired state, not notifying"
        onSuccess obj currentSt
      InvalidTransition err -> do
        phaseLog "warn" $ "Bad transition: " ++ err
        onFailure
      TransitionTo _ -> do
        applyStateChanges [stateSet obj tr]
        return [notify_done, timeout t notify_timed_out]

-- | Rule for cascading state changes
data StateCascadeRule a b where
  -- When the state of an object changes, update the state of other
  -- connected objects accordingly.
  StateCascadeRule :: (M0.HasConfObjectState a, M0.HasConfObjectState b)
                    => (M0.StateCarrier a -> Bool) --  Old state(s) if applicable
                    -> (M0.StateCarrier a -> Bool)  --  New state(s)
                    -> (a -> G.Graph -> [b]) --  Function to find new objects
                    -> (M0.StateCarrier a -> Transition b)
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
  [ AnyCascadeRule rackCascadeEnclosureRule
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

rackCascadeEnclosureRule :: StateCascadeRule M0.Rack M0.Enclosure
rackCascadeEnclosureRule = StateCascadeRule
  (M0.M0_NC_ONLINE==)
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
                      contv <- G.connectedFrom M0.IsParentOf diskv rg :: Maybe M0.ControllerV
                      enclv <- G.connectedFrom M0.IsParentOf contv rg :: Maybe M0.EnclosureV
                      rackv <- G.connectedFrom M0.IsParentOf enclv rg :: Maybe M0.RackV
                      G.connectedFrom M0.IsParentOf rackv rg :: Maybe M0.PVer]
                    guard (M0.M0_NC_FAILED /= M0.getConfObjState pver rg)
                    return pver
            in lefts $ map (checkBroken rg) pvers)
  Transition.diskChangesPVer
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg (pver@(M0.PVer _ (M0.PVerActual [_, frack, fenc, fctrl, fdisk] _))) = do
     (racksv :: [M0.RackV])       <- check frack [pver] (Proxy :: Proxy M0.Rack)
     (enclsv :: [M0.EnclosureV])  <- check fenc racksv  (Proxy :: Proxy M0.Enclosure)
     (ctrlsv :: [M0.ControllerV]) <- check fctrl enclsv  (Proxy :: Proxy M0.Controller)
     void (check fdisk ctrlsv (Proxy :: Proxy M0.Disk) :: Either M0.PVer [M0.DiskV])
     where
       check :: forall a b c . ( G.Relation M0.IsParentOf a b
                               , G.Relation M0.IsRealOf c b
                               , G.CardinalityTo M0.IsParentOf a b ~ 'G.Unbounded
                               , G.CardinalityFrom M0.IsRealOf c b ~ 'G.AtMostOne
                               , M0.HasConfObjectState c)
             => Word32 -> [a] -> Proxy c -> Either M0.PVer [b]
       check limit objects Proxy = do
         let next   = (\o -> G.connectedTo o M0.IsParentOf rg :: [b]) =<< objects
         let broken = genericLength [ realm
                                    | n     <- next
                                    , Just realm <- [G.connectedFrom M0.IsRealOf n rg :: Maybe c]
                                    , M0.M0_NC_FAILED == M0.getConfObjState realm rg
                                    ]
         when (broken > limit) $ Left pver
         return next
   checkBroken _ _ = Right ()

diskFixesPVer :: StateCascadeRule M0.Disk M0.PVer
diskFixesPVer = StateCascadeRule
  (const True)
  (M0.SDSOnline==)
  (\x rg -> let pvers = nub $
                  do diskv <- G.connectedTo x M0.IsRealOf rg :: [M0.DiskV]
                     Just pver <- [ do
                       contv <- G.connectedFrom M0.IsParentOf diskv rg :: Maybe M0.ControllerV
                       enclv <- G.connectedFrom M0.IsParentOf contv rg :: Maybe M0.EnclosureV
                       rackv <- G.connectedFrom M0.IsParentOf enclv rg :: Maybe M0.RackV
                       G.connectedFrom M0.IsParentOf rackv rg :: Maybe M0.PVer]
                     guard (M0.M0_NC_ONLINE /= M0.getConfObjState pver rg)
                     return pver
            in lefts $ map (checkBroken rg) pvers)
  Transition.diskChangesPVer
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg (pver@(M0.PVer _ (M0.PVerActual [_, frack, fenc, fctrl, fdisk] _))) = do
     (racksv :: [M0.RackV])       <- check frack [pver] (Proxy :: Proxy M0.Rack)
     (enclsv :: [M0.EnclosureV])  <- check fenc racksv  (Proxy :: Proxy M0.Enclosure)
     (ctrlsv :: [M0.ControllerV]) <- check fctrl enclsv  (Proxy :: Proxy M0.Controller)
     void (check fdisk ctrlsv (Proxy :: Proxy M0.Disk) :: Either M0.PVer [M0.DiskV])
     where
       check :: forall a b c . ( G.Relation M0.IsParentOf a b
                               , G.Relation M0.IsRealOf c b
                               , M0.HasConfObjectState c
                               , G.CardinalityTo M0.IsParentOf a b ~ 'G.Unbounded
                               , G.CardinalityFrom M0.IsRealOf c b ~ 'G.AtMostOne
                               )
             => Word32 -> [a] -> Proxy c -> Either M0.PVer [b]
       check limit objects Proxy = do
         let next   = (\o -> G.connectedTo o M0.IsParentOf rg :: [b]) =<< objects
         let broken = genericLength
               [ realm
               | n     <- next
               , Just realm <- [G.connectedFrom M0.IsRealOf n rg :: Maybe c]
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
