-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers      #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}
module HA.RecoveryCoordinator.Rules.Mero.Conf
  ( DeferredStateChanges(..)
  , applyStateChanges
  , applyStateChangesCreateFS
  , applyStateChangesSyncConfd
  , createDeferredStateChanges
  , genericApplyDeferredStateChanges
  , genericApplyStateChanges
    -- * Re-export for convenience
  , AnyStateSet(..)
  , stateSet
    -- * Temporary functions
  , applyStateChangesBlocking
  , notifyDriveStateChange
  , ExternalNotificationHandlers(..)
  , InternalNotificationHandlers(..)
    -- * Rule helpers
  , setPhaseNotified
  )  where

import HA.Encode (decodeP, encodeP)
import HA.EventQueue.Producer (promulgate)
import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Castor
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Events.Mero
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Services.Mero (notifyMeroAndThen)

import Mero.Notification (Set(..))
import Mero.Notification.HAState (Note(..))

import Control.Applicative (liftA2)
import Control.Category ((>>>))
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Distributed.Process (Process, liftIO)
import Control.Arrow (first)
import Control.Distributed.Static (Static, staticApplyPtr)
import Control.Monad (join, when, guard)
import Control.Monad.Fix (fix)

import Data.Constraint (Dict)
import Data.Foldable (forM_)
import Data.Traversable (mapAccumL)
import Data.Maybe (catMaybes)
import Data.Monoid
import Data.Typeable
import Data.List (nub, genericLength)
import Data.Either (lefts)
import Data.Functor (void)
import Data.Word

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

-- | Notify ourselves about a state change of the 'M0.SDev'.
--
-- Internally, build a note 'Set' and pass it to all registered
-- stateChangeHandlers.
--
-- TODO Remove this function.
{-# WARNING notifyDriveStateChange "Please do not use this function in new code." #-}
notifyDriveStateChange :: M0.SDev -> M0.ConfObjectState -> PhaseM LoopState l ()
notifyDriveStateChange m0sdev st = applyStateChangesCreateFS [ stateSet m0sdev st ]

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
    go :: [AnyStateChange] -> [AnyStateChange] -> (G.Graph -> G.Graph) -> (G.Graph -> G.Graph, [AnyStateChange])
    go = fix $ \f a c old_f ->
           if null a
           then (old_f, c)
           else let (updates, bs) = unzip $ liftA2 unwrap a stateCascadeRules
                    new_f = foldl (>>>) old_f (catMaybes updates)
                    b = join bs
                in f (filter (flip all c . notMatch) b) (b ++ c) (new_f)
    notMatch (AnyStateChange (a :: a) _ _ _) (AnyStateChange (b::b) _ _ _) =
       case eqT :: Maybe (a :~: b) of
         Just Refl -> a /= b
         Nothing -> True
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
                  (M0.hasStateDict :: Static (Dict (M0.HasConfObjectState a)))
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
        if (null old || a_old `elem` old) && (null new || a_new `elem` new)
        then ( Nothing
             , [ (b, b_old, b_new)
               | b <- f a rg
               , let b_old = M0.getState b rg
               , let b_new = u a_new b_old
               ])
        else (Nothing, [])
    applyCascadeRule
      (StateCascadeTrigger old new fg)
      (a, a_old, a_new) =
        if (null old || a_old `elem` old) && (null new || a_new `elem` new)
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
                         -> Process () -- ^ Callback on successful notification
                         -> Process () -- ^ Callback on failed notification
                         -> PhaseM LoopState l a
genericApplyStateChanges ass act cbSucc cbFail = getLocalGraph >>= \rg -> let
    dsc@(DeferredStateChanges _ n _) = createDeferredStateChanges ass rg
  in do
    phaseLog "state-change-set" (show n)
    genericApplyDeferredStateChanges dsc act cbSucc cbFail

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
                                 -> Process () -- ^ Callback on successful notification
                                 -> Process () -- ^ Callback on failed notification
                                 -> PhaseM LoopState l a
genericApplyDeferredStateChanges (DeferredStateChanges f s i)
                                  action cbSucc cbFail = do
  modifyGraph f
  syncGraphBlocking -- TODO Should we call this here?
  res <- action
  notifyMeroAndThen s
    (promulgate (encodeP i) >> cbSucc)
    (promulgate (encodeP i) >> cbFail)
  return res

-- | Apply state changes and do nothing else.
applyStateChanges :: [AnyStateSet]
                  -> PhaseM LoopState l ()
applyStateChanges ass =
  genericApplyStateChanges ass (return ()) (return ()) (return ())

-- | Apply state changes and synchronise with confd.
applyStateChangesSyncConfd :: [AnyStateSet]
                           -> PhaseM LoopState l ()
applyStateChangesSyncConfd ass =
    genericApplyStateChanges ass act (return ()) (return ())
  where
    act = syncAction Nothing M0.SyncToConfdServersInRG

-- | Apply state changes and create any dynamic failure sets if needed.
--   This also syncs to confd.
applyStateChangesCreateFS :: [AnyStateSet]
                          -> PhaseM LoopState l ()
applyStateChangesCreateFS ass =
    genericApplyStateChanges ass act (return ()) (return ())
  where
    act = do
      sgraph <- getLocalGraph
      mstrategy <- getCurrentStrategy
      forM_ mstrategy $ \strategy ->
        forM_ (onFailure strategy sgraph) $ \graph' -> do
          putLocalGraph graph'
          syncAction Nothing M0.SyncToConfdServersInRG

-- | Blocking version of apply state changes. DO NOT USE THIS FUNCTION in any
--   new code. All uses should be removed as soon as possible.
{-# WARNING applyStateChangesBlocking "Please do not use this function in new code." #-}
applyStateChangesBlocking :: [AnyStateSet]
                          -> PhaseM LoopState l Bool
applyStateChangesBlocking ass = do
  res <- liftIO $ newEmptyMVar
  genericApplyStateChanges ass (return ())
    (liftIO $ putMVar res True)
    (liftIO $ putMVar res False)
  liftIO $ takeMVar res

-- | @'setPhaseNotified' handle change extract act@
--
-- Create a 'RuleM' with the given @handle@ that runs the given
-- callback @act@ when internal state change notification for @change@
-- is received: effectively inside this rule we know that we have
-- notified mero about the change. @extract@ is used as a view from
-- local rule state to the object we're interested in.
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
    changeGuard _ _ l = return Nothing

-- | Rule for cascading state changes
data StateCascadeRule a b where
  StateCascadeRule :: (M0.HasConfObjectState a, M0.HasConfObjectState b)
                    => [M0.StateCarrier a] --  Old state(s) if applicable
                    -> [M0.StateCarrier a] --  New state(s)
                    -> (a -> G.Graph -> [b]) --  Function to find new objects
                    -> (M0.StateCarrier a -> M0.StateCarrier b -> M0.StateCarrier b)
                    -> StateCascadeRule a b
  StateCascadeTrigger :: (M0.HasConfObjectState a, b ~ a)
                    => [M0.StateCarrier a] --  Old state(s) if applicable
                    -> [M0.StateCarrier a] --  New state(s)
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
  [ AnyCascadeRule rackCascadeRule
  , AnyCascadeRule enclosureCascadeRule
  , AnyCascadeRule sdevCascadeRule
  , AnyCascadeRule diskFailsPVer
  , AnyCascadeRule diskFixesPVer
  , AnyCascadeRule diskAddToFailureVector
  , AnyCascadeRule diskRemoveFromFailureVector
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
  const

diskFailsPVer :: StateCascadeRule M0.Disk M0.PVer
diskFailsPVer = StateCascadeRule
  []
  [M0.M0_NC_FAILED]
  (\x rg -> let pvers = nub $ do diskv <- G.connectedTo x M0.IsRealOf rg :: [M0.DiskV]
                                 contv <- G.connectedFrom M0.IsParentOf diskv rg :: [M0.ControllerV]
                                 enclv <- G.connectedFrom M0.IsParentOf contv rg :: [M0.EnclosureV]
                                 rackv <- G.connectedFrom M0.IsParentOf enclv rg :: [M0.RackV]
                                 pver  <- G.connectedFrom M0.IsParentOf rackv rg :: [M0.PVer]
                                 guard (M0.M0_NC_FAILED /= M0.getConfObjState pver rg)
                                 return pver
            in lefts $ map (checkBroken rg) pvers)
  const
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg (pver@(M0.PVer _ [_, frack, fenc, fctrl, fdisk] _)) = do
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
  []
  [M0.M0_NC_ONLINE]
  (\x rg -> let pvers = nub $ do diskv <- G.connectedTo x M0.IsRealOf rg :: [M0.DiskV]
                                 contv <- G.connectedFrom M0.IsParentOf diskv rg :: [M0.ControllerV]
                                 enclv <- G.connectedFrom M0.IsParentOf contv rg :: [M0.EnclosureV]
                                 rackv <- G.connectedFrom M0.IsParentOf enclv rg :: [M0.RackV]
                                 pver  <- G.connectedFrom M0.IsParentOf rackv rg :: [M0.PVer]
                                 guard (M0.M0_NC_ONLINE /= M0.getConfObjState pver rg)
                                 return pver
            in lefts $ map (checkBroken rg) pvers)
  const
  where
   checkBroken :: G.Graph -> M0.PVer -> Either M0.PVer ()
   checkBroken rg (pver@(M0.PVer _ [_, frack, fenc, fctrl, fdisk] _)) = do
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
  []
  [M0.M0_NC_FAILED]
  rgRecordDiskFailure

-- | When disk becomes online we need to add that disk to the 'DiskFailureVector'.
diskRemoveFromFailureVector :: StateCascadeRule M0.Disk M0.Disk
diskRemoveFromFailureVector = StateCascadeTrigger
  []
  [M0.M0_NC_ONLINE]
  rgRecordDiskOnline
