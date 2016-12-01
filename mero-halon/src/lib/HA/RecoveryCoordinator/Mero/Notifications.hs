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
-- Interaction with flying-by state change notifications.

module HA.RecoveryCoordinator.Mero.Notifications
  ( FldNotifications
  , fldNotifications
  , mkNotifier
  , mkNotifierSimple
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

setExpectedNotifications :: forall a g l.
                            (FldNotifications a ∈ l, Application g)
                         => [a] -> PhaseM g (FieldRec l) ()
setExpectedNotifications ns = modify Local $ rlens fldN . rfield .~ ns
  where
    fldN = Proxy :: Proxy '("notifications", [a])

-- | Helper for 'setPhaseAllNotified' and 'setPhaseAllNotifiedBy'.
-- TODO: comment
mkNotifier' :: forall a l. (FldDispatch ∈ l, FldNotifications a ∈ l)
            => (a -> AnyStateChange -> Bool)
            -- ^ Underlying state transformer.
            -> Jump PhaseHandle
            -- ^ Dispatcher handle
            -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifier' toPred dispatcher = do
  notifier <- phaseHandle "notifier"

  setPhase notifier $ \(HAEvent eid (msg :: InternalObjectStateChangeMsg)) -> do
    todo eid
    let fldN = Proxy :: Proxy '("notifications", [a])
    gets Local (^. rlens fldN . rfield) >>= \case
      [] -> do
         waitDone notifier
         done eid
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
        when (null next) $ waitDone notifier
        done eid
        -- There may well be other phases this dispatcher is waiting
        -- for, we have to keep going.
        continue dispatcher

  return notifier

-- | TODO: comment
mkNotifierSimple :: (FldDispatch ∈ l, FldNotifications AnyStateSet ∈ l)
                 => Jump PhaseHandle
                 -- ^ Dispatcher handle
                 -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifierSimple = mkNotifier' simpleNotificationToPred

-- | TODO: comment
mkNotifier :: (FldDispatch ∈ l, FldNotifications (AnyStateChange -> Bool) ∈ l)
           => Jump PhaseHandle
           -- ^ Dispatcher handle
           -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkNotifier = mkNotifier' id

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
