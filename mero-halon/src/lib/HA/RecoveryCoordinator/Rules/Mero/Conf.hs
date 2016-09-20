-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE StaticPointers      #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}
module HA.RecoveryCoordinator.Rules.Mero.Conf
  ( DeferredStateChanges(..)
  , applyStateChanges
  , applyStateChangesCreateFS
  , applyStateChangesSyncConfd
    -- * Re-export for convenience
  , AnyStateSet
  , stateSet
    -- * Temporary functions
  , ExternalNotificationHandlers(..)
  , InternalNotificationHandlers(..)
    -- * Rule helpers
  , setPhaseNotified
  , setPhaseAllNotified
  , setPhaseAllNotifiedBy
  , setPhaseInternalNotification
  , setPhaseInternalNotificationWithState
  )  where

import HA.Encode (decodeP, encodeP)
import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Castor
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Events.Mero
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
import Data.Foldable (forM_)
import Data.Maybe (catMaybes, mapMaybe)
import Data.Monoid
import Data.Traversable (mapAccumL)
import Data.Typeable
import Data.List (nub, genericLength, (\\))
import Data.Either (lefts)
import Data.Functor (void)
import Data.Word
import Data.UUID (UUID)

import Network.CEP

-- | Type wrapper for external notification handlers, to be used for
-- keeping handlers in Storage.
data ExternalNotificationHandlers = ExternalNotificationHandlers
     { getExternalNotificationHandlers :: forall l . [Set -> PhaseM  LoopState l ()] }

-- | Type wrapper for internal notification handlers, to be used for
-- keeping handlers in Storage. This handlers is the point of change
-- because in future they will work on 'AnyStateChange' instead of a set.
--
-- Internal handlers works on a set of changes that actually happened
-- and stored in RG.
data InternalNotificationHandlers = InternalNotificationHandlers
     { getInternalNotificationHandlers :: forall l . [Set -> PhaseM  LoopState l ()] }

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
    applyCascadeRule
      (StateCascadeRule old new f u)
      (a, a_old, a_new) =
        if (old a_old) && (new a_new)
        then ( Nothing
             , [ (b, b_old, b_new)
               | b <- f a rg
               , let b_old = M0.getState b rg
               , let b_new = u a_new b_old
               , b_old /= b_new
               ])
        else (Nothing, [])
    applyCascadeRule
      (StateCascadeTrigger old new fg)
      (a, a_old, a_new) =
        if (old a_old) && (new a_new)
        then (Just (fg a), [])
        else (Nothing, [])

-- | Create deferred state changes for a number of objects.
--   Should implicitly cascade all necessary changes under the covers.
createDeferredStateChanges :: [AnyStateSet] -> G.Graph -> DeferredStateChanges
createDeferredStateChanges stateSets rg =
    DeferredStateChanges (fn>>>trigger_fn) (Set nvec) (InternalObjectStateChange iosc)
  where
    (trigger_fn, stateChanges) = fmap join $
        mapAccumL (\fg change -> first ((>>>) fg) (cascadeStateChange change rg)) id rootStateChanges
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
      (x@(AnyStateChange s _ s_new _):xs') -> go (f', nv', io') xs' where
        f' = f >>> M0.setState s s_new
        nv' = (Note (M0.fid s) (M0.toConfObjState s s_new)) : nv
        io' = x : io

-- | Apply a number of state changes, executing an action between updating
--   the graph and sending notifications to Mero and internally.
genericApplyStateChanges :: [AnyStateSet]
                         -> PhaseM LoopState l a
                         -> PhaseM LoopState l a
genericApplyStateChanges ass act = getLocalGraph >>= \rg ->
  genericApplyDeferredStateChanges (createDeferredStateChanges ass rg) act

-- | Generic function to apply deferred state changes in the standard order.
--   The provided 'action' is executed between updating the graph and sending
--   both 'Set' and 'InternalObjectStateChange' messages. The provided Process
--   actions are called after sending notification to Mero, should this succeed
--   or fail respectively.
--
--   For more flexibility, you can write your own apply method which takes
--   a `DeferredStateChanges` argument.
genericApplyDeferredStateChanges :: DeferredStateChanges
                                 -> PhaseM LoopState l a -- ^ action
                                 -> PhaseM LoopState l a
genericApplyDeferredStateChanges (DeferredStateChanges f s i) action = do
  diff <- mkStateDiff f (encodeP i) []
  notifyMeroAsync diff s
  action


-- | Apply state changes and do nothing else.
applyStateChanges :: [AnyStateSet]
                  -> PhaseM LoopState l ()
applyStateChanges ass =
    genericApplyStateChanges ass (return ())

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

-- | @'setPhaseNotified' handle change extract act@
--
-- Create a 'RuleM' with the given @handle@ that runs the given
-- callback @act@ when internal state change notification for @change@
-- is received: effectively inside this rule we know that we have
-- notified mero about the change. @extract@ is used as a view from
-- local rule state to the object we're interested in.
--
-- TODO: Do we need to handle UUID here?
setPhaseNotified :: forall b l g.
                    (M0.HasConfObjectState b, Typeable (M0.StateCarrier b))
                 => Jump PhaseHandle
                 -> (l -> Maybe (b, M0.StateCarrier b))
                 -> ((b, M0.StateCarrier b) -> PhaseM g l ())
                 -> RuleM g l ()
setPhaseNotified handle extract act =
  setPhaseIf handle changeGuard act
  where
    extractStateSet (AnyStateChange a _ n _) = AnyStateSet a n

    changeGuard :: HAEvent InternalObjectStateChangeMsg
                -> g -> l -> Process (Maybe (b, M0.StateCarrier b))
    changeGuard (HAEvent _ msg _) _ (extract -> Just (obj, change)) =
      (liftProcess . decodeP $ msg) >>= \(InternalObjectStateChange iosc) -> do
        if stateSet obj change `elem` map extractStateSet iosc
        then return $ Just (obj, change)
        else return Nothing
    changeGuard _ _ _ = return Nothing

-- | Similar to 'setPhaseNotified' but works on a set of notifications
-- rather than a singular one.
--
-- State will endup in either @Nothing@ or @Just []@ depends on lens
-- implementation.
setPhaseAllNotified :: forall l g. Jump PhaseHandle
                    -> (Lens' l (Maybe [AnyStateSet]))
                    -> PhaseM g l () -- ^ Callback when set has been notified
                    -> RuleM g l ()
setPhaseAllNotified handle extract act =
  setPhase handle $ \(HAEvent _ msg _) -> do
     mn <- gets Local (^. extract)
     case mn of
       Nothing -> do phaseLog "error" "Internal noficications are not set."
                     act
       Just notificationSet -> do
         InternalObjectStateChange iosc <- liftProcess . decodeP $ (msg :: InternalObjectStateChangeMsg)
         let internalStateSet = map extractStateSet iosc
             next = notificationSet \\ internalStateSet
         modify Local $ set extract (Just next)
         case next of
           [] -> act
           _  -> continue handle
  where
    extractStateSet (AnyStateChange a _ n _) = stateSet a n

-- | Similar to 'setPhaseAllNotified' but takes a list of predicates which
-- may be satisfied by an incoming notification. When all predicates have
-- been satisfied, enter the phase.
--
-- State will endup in either @Nothing@ or @Just []@ depends on lens
-- implementation.
setPhaseAllNotifiedBy :: forall l g. Jump PhaseHandle
                      -> (Lens' l (Maybe [AnyStateSet -> Bool]))
                      -> PhaseM g l () -- ^ Callback when set has been notified
                      -> RuleM g l ()
setPhaseAllNotifiedBy handle extract act =
  setPhase handle $ \(HAEvent _ msg _) -> do
     mn <- gets Local (^. extract)
     case mn of
       Nothing -> do phaseLog "error" "Internal noficications are not set."
                     act
       Just notificationSet -> do
         InternalObjectStateChange iosc <- liftProcess . decodeP $ (msg :: InternalObjectStateChangeMsg)
         let internalStateSet = map extractStateSet iosc
             next = filter (\f -> not $ any f internalStateSet) notificationSet
         modify Local $ set extract (Just next)
         case next of
           [] -> act
           _  -> continue handle
  where
    extractStateSet (AnyStateChange a _ n _) = stateSet a n

-- | As 'setPhaseInternalNotificationWithState', accepting all object states.
setPhaseInternalNotification :: forall b l g.
                                (M0.HasConfObjectState b, Typeable (M0.StateCarrier b))
                                => Jump PhaseHandle
                                -> ((UUID, [(b, M0.StateCarrier b)]) -> PhaseM g l ())
                                -> RuleM g l ()
setPhaseInternalNotification handle act =
  setPhaseInternalNotificationWithState handle (const $ const True) act

-- | Given a predicate on object state, retrieve all objects and
-- states satisfying the predicate from the internal state change
-- notification.
setPhaseInternalNotificationWithState :: forall b l g.
                                      (M0.HasConfObjectState b, Typeable (M0.StateCarrier b))
                                      => Jump PhaseHandle
                                      -> (M0.StateCarrier b -> M0.StateCarrier b -> Bool)
                                      -> ((UUID, [(b, M0.StateCarrier b)]) -> PhaseM g l ())
                                      -> RuleM g l ()
setPhaseInternalNotificationWithState handle p act = setPhaseIf handle changeGuard act
  where
    changeGuard :: HAEvent InternalObjectStateChangeMsg
                -> g -> l -> Process (Maybe (UUID, [(b, M0.StateCarrier b)]))
    changeGuard (HAEvent eid msg _) _ _ =
      (liftProcess . decodeP $ msg) >>= \(InternalObjectStateChange iosc) ->
        case mapMaybe getObjP iosc of
          [] -> return Nothing
          objs -> return $ Just (eid, objs)

    getObjP x = case x of
      AnyStateChange (a::z) o n _ -> case eqT :: Maybe (z :~: b) of
        Just Refl | p o n -> Just (a,n)
        _ -> Nothing

-- | Rule for cascading state changes
data StateCascadeRule a b where
  -- When the state of an object changes, update the state of other
  -- connected objects accordingly.
  StateCascadeRule :: (M0.HasConfObjectState a, M0.HasConfObjectState b)
                    => (M0.StateCarrier a -> Bool) --  Old state(s) if applicable
                    -> (M0.StateCarrier a -> Bool)  --  New state(s)
                    -> (a -> G.Graph -> [b]) --  Function to find new objects
                    -> (M0.StateCarrier a -> M0.StateCarrier b -> M0.StateCarrier b)
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
  , AnyCascadeRule serviceCascadeDiskRule
  ] ++ (AnyCascadeRule <$> enclosureCascadeControllerRules)
    ++ (AnyCascadeRule <$> iosFailsController)

rackCascadeEnclosureRule :: StateCascadeRule M0.Rack M0.Enclosure
rackCascadeEnclosureRule = StateCascadeRule
  (M0.M0_NC_ONLINE==)
  (`elem` [M0.M0_NC_FAILED, M0.M0_NC_TRANSIENT])
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  (const $ const M0.M0_NC_TRANSIENT)  -- XXX: what if enclosure if failed (?)

enclosureCascadeControllerRules :: [StateCascadeRule M0.Enclosure M0.Controller]
enclosureCascadeControllerRules =
  [ StateCascadeRule
      (M0.M0_NC_ONLINE ==)
      (`elem` [M0.M0_NC_FAILED, M0.M0_NC_TRANSIENT])
      (\x rg -> G.connectedTo x M0.IsParentOf rg)
      (const $ const M0.CSTransient)
  , StateCascadeRule
      (M0.M0_NC_ONLINE /=)
      (M0.M0_NC_ONLINE ==)
      (\x rg -> G.connectedTo x M0.IsParentOf rg)
      (const $ const M0.CSOnline)
  ]

processCascadeServiceRule :: StateCascadeRule M0.Process M0.Service
processCascadeServiceRule = StateCascadeRule
    (const True)
    (const True)
    (\x rg -> G.connectedTo x M0.IsParentOf rg)
    (\s o -> case s of
              M0.PSStarting -> M0.SSStarting -- error "M0.SSStarting"
              M0.PSOnline -> M0.SSOnline
              M0.PSOffline
                | o == M0.SSFailed -> o
                | otherwise -> M0.SSOffline
              M0.PSFailed _
                | o == M0.SSFailed -> o
                | inhibited o -> o
                | otherwise -> M0.SSInhibited o
              M0.PSQuiescing
                | o `elem` [M0.SSFailed, M0.SSOffline] -> o
                | inhibited o -> o
                | otherwise -> M0.SSInhibited o
              M0.PSStopping
                | o == M0.SSFailed -> o
                | otherwise -> M0.SSStopping
              M0.PSInhibited _
                | o == M0.SSFailed -> o
                | inhibited o -> o
                | otherwise -> M0.SSInhibited o
              M0.PSUnknown -> o)
  where
    inhibited (M0.SSInhibited _) = True
    inhibited _ = False

serviceCascadeDiskRule :: StateCascadeRule M0.Service M0.SDev
serviceCascadeDiskRule = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  (\s o  ->
     let break' M0.SDSFailed  = M0.SDSFailed
         break' (M0.SDSTransient x) = M0.SDSTransient x
         break' x = M0.SDSTransient x
         unbreak (M0.SDSTransient x) = x
         unbreak x = x
     in case s of
          M0.SSUnknown  -> o
          M0.SSOffline  -> break' o
          M0.SSFailed   -> break' o
          M0.SSStarting -> unbreak o
          M0.SSOnline   -> unbreak o
          M0.SSStopping -> break' o
          M0.SSInhibited _ -> break' o)

-- | This is a rule which interprets state change events and is responsible for
-- changing the state of the cluster accordingly'
nodeFailsProcessRule :: StateCascadeRule M0.Node M0.Process
nodeFailsProcessRule = StateCascadeRule
  (const True)
  (\x -> M0.NSFailed == x || M0.NSFailedUnrecoverable == x)
  (\x rg -> G.connectedTo x M0.IsParentOf rg)
  (\_ o -> case o of
    x@(M0.PSInhibited _) -> x
    y -> M0.PSInhibited y
  )

-- This is a phantom rule; SDev state is queried through Disk state,
-- so this rule just exists to include the `SDev` in the set of
-- notifications which get sent out.
sdevCascadeDisk :: StateCascadeRule M0.SDev M0.Disk
sdevCascadeDisk = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> G.connectedTo x M0.IsOnHardware rg)
  const

diskCascadeSdev :: StateCascadeRule M0.Disk M0.SDev
diskCascadeSdev = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> G.connectedFrom M0.IsOnHardware x rg)
  const

nodeCascadeController :: StateCascadeRule M0.Node M0.Controller
nodeCascadeController = StateCascadeRule
  (const True)
  (const True)
  (\x rg -> G.connectedTo x M0.IsOnHardware rg)
  (\s o -> case s of
            M0.NSUnknown -> o
            M0.NSOnline -> M0.CSOnline
            _ -> M0.CSTransient
  )

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
          _ -> []
        )
        (\_ _ -> M0.CSTransient)
    , StateCascadeRule
        (const True)  -- XXX: this is workaround as halon sets IOS to unknown
                      -- in prior to cluster start. As a result this rule never
                      -- started upon a restart.
        (not . serviceFailed)
        (\x rg -> case M0.s_type x of
          CST_IOS ->  iosToController rg x
          _ -> []
        )
        (\_ _ -> M0.CSOnline)
    ]
  where
    serviceFailed M0.SSFailed = True
    serviceFailed (M0.SSInhibited _) = True
    serviceFailed (M0.SSOffline) = True
    serviceFailed _ = False
    iosToController rg x =
      [ controller
      | (proc :: M0.Process) <- G.connectedFrom M0.IsParentOf x rg
      , (node :: M0.Node) <- G.connectedFrom M0.IsParentOf proc rg
      , controller <- G.connectedTo node M0.IsOnHardware rg
      ]

diskFailsPVer :: StateCascadeRule M0.Disk M0.PVer
diskFailsPVer = StateCascadeRule
  (const True)
  (M0.SDSFailed ==)
  (\x rg -> let pvers = nub $ do diskv <- G.connectedTo x M0.IsRealOf rg :: [M0.DiskV]
                                 contv <- G.connectedFrom M0.IsParentOf diskv rg :: [M0.ControllerV]
                                 enclv <- G.connectedFrom M0.IsParentOf contv rg :: [M0.EnclosureV]
                                 rackv <- G.connectedFrom M0.IsParentOf enclv rg :: [M0.RackV]
                                 pver  <- G.connectedFrom M0.IsParentOf rackv rg :: [M0.PVer]
                                 guard (M0.M0_NC_FAILED /= M0.getConfObjState pver rg)
                                 return pver
            in lefts $ map (checkBroken rg) pvers)
  (\a _ -> M0.toConfObjState (undefined :: M0.Disk) a)
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg (pver@(M0.PVer _ (M0.PVerActual [_, frack, fenc, fctrl, fdisk] _))) = do
     (racksv :: [M0.RackV])       <- check frack [pver] (Proxy :: Proxy M0.Rack)
     (enclsv :: [M0.EnclosureV])  <- check fenc racksv  (Proxy :: Proxy M0.Enclosure)
     (ctrlsv :: [M0.ControllerV]) <- check fctrl enclsv  (Proxy :: Proxy M0.Controller)
     void (check fdisk ctrlsv (Proxy :: Proxy M0.Disk) :: Either M0.PVer [M0.DiskV])
     where
       check :: forall a b c . (G.Relation M0.IsParentOf a b, G.Relation M0.IsRealOf c b, M0.HasConfObjectState c)
             => Word32 -> [a] -> Proxy c -> Either M0.PVer [b]
       check limit objects Proxy = do
         let next   = (\o -> G.connectedTo o M0.IsParentOf rg :: [b]) =<< objects
         let broken = genericLength [ realm
                                    | n     <- next
                                    , realm <- G.connectedFrom M0.IsRealOf n rg :: [c]
                                    , M0.M0_NC_FAILED == M0.getConfObjState realm rg
                                    ]
         when (broken > limit) $ Left pver
         return next
   checkBroken _ _ = Right ()

diskFixesPVer :: StateCascadeRule M0.Disk M0.PVer
diskFixesPVer = StateCascadeRule
  (const True)
  (M0.SDSOnline==)
  (\x rg -> let pvers = nub $ do diskv <- G.connectedTo x M0.IsRealOf rg :: [M0.DiskV]
                                 contv <- G.connectedFrom M0.IsParentOf diskv rg :: [M0.ControllerV]
                                 enclv <- G.connectedFrom M0.IsParentOf contv rg :: [M0.EnclosureV]
                                 rackv <- G.connectedFrom M0.IsParentOf enclv rg :: [M0.RackV]
                                 pver  <- G.connectedFrom M0.IsParentOf rackv rg :: [M0.PVer]
                                 guard (M0.M0_NC_ONLINE /= M0.getConfObjState pver rg)
                                 return pver
            in lefts $ map (checkBroken rg) pvers)
  (\a _ -> M0.toConfObjState (undefined :: M0.Disk) a)
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg (pver@(M0.PVer _ (M0.PVerActual [_, frack, fenc, fctrl, fdisk] _))) = do
     (racksv :: [M0.RackV])       <- check frack [pver] (Proxy :: Proxy M0.Rack)
     (enclsv :: [M0.EnclosureV])  <- check fenc racksv  (Proxy :: Proxy M0.Enclosure)
     (ctrlsv :: [M0.ControllerV]) <- check fctrl enclsv  (Proxy :: Proxy M0.Controller)
     void (check fdisk ctrlsv (Proxy :: Proxy M0.Disk) :: Either M0.PVer [M0.DiskV])
     where
       check :: forall a b c . (G.Relation M0.IsParentOf a b, G.Relation M0.IsRealOf c b, M0.HasConfObjectState c)
             => Word32 -> [a] -> Proxy c -> Either M0.PVer [b]
       check limit objects Proxy = do
         let next   = (\o -> G.connectedTo o M0.IsParentOf rg :: [b]) =<< objects
         let broken = genericLength [ realm
                                    | n     <- next
                                    , realm <- G.connectedFrom M0.IsRealOf n rg :: [c]
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
