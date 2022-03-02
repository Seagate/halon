{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE StaticPointers   #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Notifications
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Interaction with flying-by state change notifications. A simple
-- use-case may look as follows:
--
-- @
-- ruleNotifyProcessOnline :: 'Definitions' 'RC' ()
-- ruleNotifyProcessOnline = 'define' "ruleNotifyProcessOnline" $ do
--   notify_process_online <- 'phaseHandle' "notify_process_online"
--   notify_succeeded <- 'phaseHandle' "notify_succeeded"
--   notify_timed_out <- 'phaseHandle' "notify_timed_out"
--   dispatcher <- 'mkDispatcher'
--   notifier <- 'mkNotifierSimple' dispatcher
--
--   'setPhase' notify_process_online $ \(SomeProcess p) -> do
--     notifications <- 'applyStateChanges' ['stateSet' p processOnline]
--     'setExpectedNotifications' notifications
--     'waitFor' notifier
--     'onTimeout' 10 notify_timed_out
--     'onSuccess' notify_succeeded
--     'continue' dispatcher
--
--   'directly' notify_succeeded $ …
--   'directly' notify_timed_out $ …
--
--   'start' notify_process_online (args notify_succeeded)
--   where
--     args st =  'fldNotifications' '=:' []
--          '<+>' 'fldDispatch'      '=:' 'Dispatch' [] st 'Nothing'
-- @

module HA.RecoveryCoordinator.Mero.Notifications
  ( FldNotifications
  , fldNotifications
  , mkNotifier
  , mkNotifierAct
  , mkNotifierSimple
  , mkNotifierSimpleAct
  , setExpectedNotifications
  , setPhaseInternalNotification
  , setPhaseNotified
  , simpleNotificationToPred
  , module HA.RecoveryCoordinator.RC.Actions.Dispatch
  ) where

import           Control.Distributed.Process (Process)
import           Control.Lens
import           Data.List (foldl')
import           Data.Maybe (listToMaybe, mapMaybe)
import           Data.Typeable
import           Data.UUID (UUID)
import           Data.Vinyl hiding ((:~:))
import           HA.Encode (decodeP)
import           HA.EventQueue (HAEvent(..))
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.Mero.Transitions.Internal
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Actions.Dispatch
import qualified HA.Resources.Mero.Note as M0
import           Network.CEP

-- | Field holding some type of notifications
type FldNotifications a = '("notifications", [a])

-- | An instance of 'FldNotifications' field over 'AnyStateSet'.
fldNotifications :: Proxy (FldNotifications AnyStateChange)
fldNotifications = Proxy

-- | A helper to set 'FldNotifications' in the local state.
setExpectedNotifications :: forall a g l.
                            (FldNotifications a ∈ l, Application g)
                         => [a] -> PhaseM g (FieldRec l) ()
setExpectedNotifications ns = modify Local $ rlens fldN . rfield .~ ns
  where
    fldN = Proxy :: Proxy (FldNotifications a)

-- | Create a phase that awaits state change notifications. This phase
-- is driven by a dispatcher ('FldDispatch') which allows us to
-- interleave waits with other phases and easily set failure and
-- success cases. Most likely you want to use one of
-- 'mkNotifierSimpleAct', 'mkNotifierSimple', 'mkNotifier'.
mkNotifier' :: forall a l. (FldDispatch ∈ l, FldNotifications a ∈ l)
            => (a -> AnyStateChange -> Bool)
            -- ^ Underlying state predicate generator. Given value in
            -- 'FldNotifications' of type @a@, generate a predicate on
            -- 'AnyStateChange' that we actually receive and see if
            -- the two ‘match’.
            -> Jump PhaseHandle
            -- ^ Dispatcher handle.
            -> PhaseM RC (FieldRec l) ()
            -- ^ Any extra action to perform when the notifier phase
            -- is finished. Useful if you want to 'waitDone' or
            -- 'waitClear' some extra phase handles.
            -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifier' toPred dispatcher act = do
  check_notifications <- phaseHandle "check_notifications"
  notifier <- phaseHandle "notifier"
  let fldN = Proxy :: Proxy (FldNotifications a)

  -- It could happen that the caller invoked the notifier without any
  -- notifications. In that case the caller has to wait for
  -- 'InternalObjectStateChangeMsg' to fly by to notice this: this is
  -- sub-optimal because dispatcher can then happily timeout if we're
  -- not lucky and some other component in the system causes a state
  -- change. We prevent this situation by checking if there are any
  -- notifications to wait for at all: if not then we're finished
  -- straight away.
  directly check_notifications $ do
    gets Local (^. rlens fldN . rfield) >>= \case
      [] -> do
        Log.rcLog' Log.DEBUG "No notifications given, completing trivially."
        waitDone check_notifications
        act
        continue dispatcher
      _ -> do
        -- We have some notifications to wait for so add the actual
        -- handling phase to the dispatcher and just let the
        -- dispatcher work as always.
        waitDone check_notifications
        waitFor notifier
        continue dispatcher

  setPhase notifier $ \(HAEvent eid (msg :: InternalObjectStateChangeMsg)) -> do
    let notifierDone = do
          waitDone notifier
          done eid
          act
          -- There may well be other phases the dispatcher is waiting
          -- for, we have to keep going.
          continue dispatcher
    todo eid
    gets Local (^. rlens fldN . rfield) >>= \case
      [] -> notifierDone
      notificationSet -> do
        InternalObjectStateChange iosc <- liftProcess $ decodeP msg
        -- O(n*(max(n, m))) i.e. at least O(n²) but possibly worse
        -- n = length notificationSet
        -- m = length iosc
        let next = foldl' (\sts asc -> filter (\s -> not $ toPred s asc) sts)
                          notificationSet iosc
        modify Local $ rlens fldN . rfield .~ next
        case next of
          -- We're not waiting for any more notifications.
          [] -> notifierDone
          -- It may happen that the notifications can come in separate
          -- state diffs. For example consider wanting to wait for all
          -- notifications for some objects but the rule pertaining to
          -- the object only notifies about one object at a time. This
          -- is not the usual scenario however and can indicate a bug
          -- in user code (for example user is waiting for
          -- notification for an object that state change mechanism
          -- decided notification is not needed for) so log when it
          -- happens.
          _ -> do
            Log.rcLog' Log.DEBUG "Still waiting for notifications."
            done eid
            continue notifier

  return check_notifications

-- | A wrapper over 'mkNotifier'' that works over @'FldNotifications'
-- 'AnyStateSet'@ and allows the user to specify an additional action
-- to perform after the notification phase is finished working. This
-- action can be used to perform any additional clean-up, such as by
-- removing ('waitDone') any potential abort phases &c.
mkNotifierSimpleAct :: (FldDispatch ∈ l, FldNotifications AnyStateChange ∈ l)
                    => Jump PhaseHandle
                    -- ^ Dispatcher handle
                    -> PhaseM RC (FieldRec l) ()
                    -- ^ Act to perform after notifier phase is finished.
                    -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifierSimpleAct = mkNotifier' (==)

-- | 'mkNotifierSimpleAct' with an action that does nothing.
mkNotifierSimple :: (FldDispatch ∈ l, FldNotifications AnyStateChange ∈ l)
                 => Jump PhaseHandle
                 -- ^ Dispatcher handle
                 -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifierSimple h = mkNotifier' (==) h (return ())

-- | 'mkNotifierSimpleAct' where notification set is already in
-- @'AnyStateChange -> 'Bool'@ form.
mkNotifierAct :: (FldDispatch ∈ l, FldNotifications (AnyStateChange -> Bool) ∈ l)
              => Jump PhaseHandle
              -- ^ Dispatcher handle
              -> PhaseM RC (FieldRec l) ()
              -- ^ Act to perform after notifier phase is finished.
              -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifierAct = mkNotifier' id

-- | 'mkNotifierSimple' that works directly over 'AnyStateChange'
-- predicates stored in 'FldNotifications'.
mkNotifier :: (FldDispatch ∈ l, FldNotifications (AnyStateChange -> Bool) ∈ l)
           => Jump PhaseHandle
           -- ^ Dispatcher handle
           -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifier h = mkNotifierAct h (return ())

-- | Check that the 'AnyStateChange' directly corresponds to
-- 'Transition' encoded in the 'AnyStateSet'.
--
-- Note that transitions that cause no state change ('NoTransition')
-- match on every 'AnyStateChange' for their object type. This allows
-- us to eliminate these transitions when looking through the set of
-- 'AnyStateChange's.
simpleNotificationToPred :: AnyStateSet -> AnyStateChange -> Bool
simpleNotificationToPred (AnyStateSet (a :: a) tr) (AnyStateChange (obj :: b) o n _) =
  case eqT of
    Just (Refl :: a :~: b) | obj == a -> case runTransition tr o of
      TransitionTo n' -> n == n'
      NoTransition -> True
      _ -> False
    _ -> False

-- | Given a predicate on object state, retrieve all objects and
-- states satisfying the predicate from the internal state change
-- notification.
--
-- TODO: improve
setPhaseInternalNotification :: forall app b l g.
                                ( Application app
                                , g ~ GlobalState app
                                , M0.HasConfObjectState b
                                , Typeable (M0.StateCarrier b))
                             => Jump PhaseHandle
                             -> (M0.StateCarrier b -> M0.StateCarrier b -> Bool)
                             -> ((UUID, [(b, M0.StateCarrier b)]) -> PhaseM app l ())
                             -> RuleM app l ()
setPhaseInternalNotification handle p act =
  setPhase handle $ \(HAEvent eid (msg :: InternalObjectStateChangeMsg)) -> do
    InternalObjectStateChange iosc <- liftProcess $ decodeP msg
    case mapMaybe getObjP iosc of
      []   -> continue handle
      objs -> act (eid, objs)
  where
    getObjP :: AnyStateChange -> Maybe (b, M0.StateCarrier b)
    getObjP (AnyStateChange (obj :: a) old new _) =
      case eqT :: Maybe (a :~: b) of
        Just Refl | p old new -> Just (obj, new)
        _ -> Nothing

-- | @'setPhaseNotified' handle change extract act@
--
-- Create a 'RuleM' with the given @handle@ that runs the given
-- callback @act@ when internal state change notification for @change@
-- is received: effectively inside this rule we know that we have
-- notified mero about the change. @extract@ is used as a view from
-- local rule state to the object we're interested in.
--
-- TODO: Do we need to handle UUID here?
-- TODO: improve
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
