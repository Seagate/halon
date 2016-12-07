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
-- License   : All rights reserved.
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
--     let notifications = [stateSet p processOnline]
--     'setExpectedNotifications' notifications
--     'applyStateChanges' notifications
--     'waitFor' notify_succeeded
--     'onTimeout' 10 notify_timed_out
--     'onSuccess' notify_succeeded
--     'continue' dispatcher
--
--   'directly' notify_succeeded $ …
--   'directly' notify_timed_out $ …
--
--   start notify_process_online (args notify_process_online)
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
  ) where

import           Control.Distributed.Process (Process)
import           Control.Lens
import           Control.Monad (when)
import           Data.List (foldl')
import           Data.Maybe (listToMaybe, mapMaybe)
import           Data.Typeable
import           Data.UUID (UUID)
import           Data.Vinyl hiding ((:~:))
import           HA.Encode (decodeP)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.Mero.Transitions.Internal
import           HA.RecoveryCoordinator.RC.Actions.Core
import           HA.RecoveryCoordinator.RC.Actions.Dispatch
import qualified HA.Resources.Mero.Note as M0
import           Network.CEP

-- | Field holding some type of notifications
type FldNotifications a = '("notifications", [a])

-- | An instance of 'FldNotifications' field over 'AnyStateSet'.
fldNotifications :: Proxy (FldNotifications AnyStateSet)
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
  notifier <- phaseHandle "notifier"

  setPhase notifier $ \(HAEvent eid (msg :: InternalObjectStateChangeMsg)) -> do
    todo eid
    let fldN = Proxy :: Proxy '("notifications", [a])
    gets Local (^. rlens fldN . rfield) >>= \case
      [] -> do
         waitDone notifier
         done eid
         act
         continue dispatcher
      notificationSet -> do
        InternalObjectStateChange iosc <- liftProcess $ decodeP msg
        -- O(n*(max(n, m))) i.e. at least O(n²) but possibly worse
        -- n = length notificationSet
        -- m = length iosc
        let next = foldl' (\sts asc -> filter (\s -> not $ toPred s asc) sts)
                          notificationSet iosc
        modify Local $ rlens fldN . rfield .~ next

        -- We're not waiting for any more notifications, notifier has
        -- done its job.
        when (null next) $ do
          waitDone notifier
          done eid
          act
        -- There may well be other phases this dispatcher is waiting
        -- for, we have to keep going.
        continue dispatcher

  return notifier

-- | A wrapper over 'mkNotifier'' that works over @'FldNotifications'
-- 'AnyStateSet'@ and allows the user to specify an additional action
-- to perform after the notification phase is finished working. This
-- action can be used to perform any additional clean-up, such as by
-- removing ('waitDone') any potential abort phases &c.
mkNotifierSimpleAct :: (FldDispatch ∈ l, FldNotifications AnyStateSet ∈ l)
                    => Jump PhaseHandle
                    -- ^ Dispatcher handle
                    -> PhaseM RC (FieldRec l) ()
                    -- ^ Act to perform after notifier phase is finished.
                    -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifierSimpleAct = mkNotifier' simpleNotificationToPred

-- | 'mkNotifierSimpleAct' with an action that does nothing.
mkNotifierSimple :: (FldDispatch ∈ l, FldNotifications AnyStateSet ∈ l)
                 => Jump PhaseHandle
                 -- ^ Dispatcher handle
                 -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifierSimple h = mkNotifier' simpleNotificationToPred h (return ())

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
simpleNotificationToPred (AnyStateSet a tr) (AnyStateChange (obj :: objT) o n _) =
  case (cast a, cast tr) of
    (Just (a' :: objT), Just (tr' :: Transition objT)) ->
      obj == a' && case runTransition tr' o of
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
setPhaseInternalNotification handle p act = setPhaseIf handle changeGuard act
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
