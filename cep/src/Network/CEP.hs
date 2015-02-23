{-# LANGUAGE BangPatterns, RankNTypes, ScopedTypeVariables  #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--

module Network.CEP
       ( module Network.CEP.Types
       , decoded
       , listen
       , listenMessage
       , publish
       , repeatedly
       , repeatedlyOnMessage
       , runProcessor
       , runProcessor_
       , simpleSubscribe
       , subscribe
       , decodedEvent
       , snapshot
       , buildProcess
       , buildFromRuleM
       , buildFromRuleMS
       , mkGenS
       , mkPureS
       , occursWithin
       ) where

import Prelude hiding ((.), id)
import Data.Monoid
import Unsafe.Coerce

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad.Reader
import           Control.Monad.State hiding (state)
import           Control.Wire.Core
import           Control.Wire.Unsafe.Event
import qualified Data.MultiMap as M
import           Data.Time
import           FRP.Netwire

import Network.CEP.Types

simpleSubscribe :: Serializable a => ProcessId -> Sub a -> Process ()
simpleSubscribe pid sub = do
    self <- getSelfPid
    let key  = fingerprint sub
        fgBs = encodeFingerprint key
    send pid (Subscribe fgBs self)

subscribe :: Serializable a => ProcessId -> Sub a -> CEP ()
subscribe pid sub = liftProcess $ simpleSubscribe pid sub

publish :: Serializable a => a -> CEP ()
publish a = CEP $ do
    subs <- gets _subscribers
    self <- lift getSelfPid
    let sub = asSub a
        key = fingerprint sub

    lift $ forM_ (M.lookup key subs) $ \pid ->
      send pid (Published a self)

repeatedly :: Monoid s => (s -> a -> CEP s) -> ComplexEvent s a s
repeatedly k = go
  where
    go = mkGen $ \t a -> do
        s' <- k (dstate t) a
        return (Right s', go)

repeatedlyOnMessage :: (Monoid s, Serializable a)
                    => (s -> a -> CEP s)
                    -> ComplexEvent s Input s
repeatedlyOnMessage k = repeatedly k . decoded

listen :: (a -> CEP b) -> ComplexEvent s a ()
listen k = mkGen_ $ \a -> do
    _ <- k a
    return (Right ())

listenMessage :: Serializable a => (a -> CEP b) -> ComplexEvent s Input ()
listenMessage k = listen k . decoded

runProcessor :: TypeMatch a
             => a
             -> ComplexEvent s Input s
             -> s
             -> Process b
runProcessor def startWire start =
    go emptyBookkeeping clockSession start startWire
  where
    matches = match (return . SubRequest) : typematch def
    emptyBookkeeping = Bookkeeping M.empty
    go book session state wire = do
        cepMsg <- receiveWait matches
        case cepMsg of
          SubRequest sub ->
            let key     = decodeFingerprint $ _subType sub
                value   = _subPid sub
                newMap  = M.insert key value (_subscribers book)
                newBook = book { _subscribers = newMap } in
            go newBook session state wire
          Other msg -> do
            (step, nextSession) <- stepSession session
            let action = stepWire wire (Ctx $ step state) (Right msg)
            ((res, newWire), newBook) <- runCEP action book
            case res of
              Right newState -> go newBook nextSession newState newWire
              Left _         -> go newBook nextSession state newWire

runProcessor_ :: TypeMatch a
              => a
              -> (forall s. ComplexEvent s Input b)
              -> Process c
runProcessor_ def startWire =
    go emptyBookkeeping clockSession startWire
  where
    matches = match (return . SubRequest) : typematch def
    emptyBookkeeping = Bookkeeping M.empty
    go book session wire = do
        cepMsg <- receiveWait matches
        case cepMsg of
          SubRequest sub ->
            let key     = decodeFingerprint $ _subType sub
                value   = _subPid sub
                newMap  = M.insert key value (_subscribers book)
                newBook = book { _subscribers = newMap } in
            go newBook session wire
          Other msg -> do
            (step, nextSession) <- stepSession session
            let action = stepWire wire (Ctx $ step ()) (Right msg)
            ((res, newWire), newBook) <- runCEP action book
            case res of
              Right _ -> go newBook nextSession newWire
              Left  _ -> go newBook nextSession newWire

buildFromRuleM :: Monoid s => RuleM s () -> Process a
buildFromRuleM = buildFromRuleMS mempty

buildFromRuleMS :: s -> RuleM s () -> Process a
buildFromRuleMS start rm = go start clockSession (cepRules rs)
  where
    rs = runRuleM rm

    matches = cepMatches rs

    go s session wire = do
        dyn <- receiveWait matches
        (step, nextSession) <- stepSession session
        let action = stepWire wire (Ctx $ step s) (Right dyn)
        ((res, nextWire), _) <- runCEP action initBookkeeping
        case res of
          Right s' -> go s' nextSession nextWire
          Left _   -> go s nextSession nextWire

initBookkeeping :: Bookkeeping
initBookkeeping = Bookkeeping M.empty

buildProcess :: (forall a s. Monoid s => ComplexEvent s a ())
             -> Process b
buildProcess startWire = go initBookkeeping clockSession_ startWire
  where
    go book session wire = do
        (step, next) <- stepSession session
        let action = stepWire wire (Ctx step) (Right ())
        ((_, newWire), newBook) <- runCEP action book
        go newBook next newWire

decoded :: forall a s. Serializable a => ComplexEvent s Input a
decoded = mkGen_ $ \(Input fprint rawmsg) ->
    if fprint == fingerprint (undefined :: a)
       then let msg = unsafeCoerce rawmsg :: a
            in Right msg <$ publish msg
    else return $ Left ()

decodedEvent :: forall a s. Serializable a => ComplexEvent s Input (Event a)
decodedEvent = mkGen_ $ \(Input fprint rawmsg) ->
    if fprint == fingerprint (undefined :: a)
       then let msg = unsafeCoerce rawmsg :: a
            in (Right $ Event msg) <$ publish msg
    else return $ Right NoEvent

snapshot :: ComplexEvent s (Event a, b) (Event (a, b))
snapshot = mkSF_ go
  where
    go (Event a, b) = Event (a, b)
    go _            = NoEvent

mkGenS :: Monad m
       => (s -> a -> m (Either e b, Wire s e m a b))
       -> Wire s e m a b
mkGenS k = go
  where
    go = WGen $ \ds mx ->
        case mx of
          Left e  -> return (Left e, go)
          Right x -> liftM lstrict (k ds x)

mkPureS :: (s -> a -> (Either e b, Wire s e m a b)) -> Wire s e m a b
mkPureS k = go
  where
    go = WPure $ \ds mx ->
        case mx of
          Left e  -> (Left e, go)
          Right x -> lstrict $ k ds x

occursWithin :: Monoid s => Int -> NominalDiffTime -> ComplexEvent s a a
occursWithin cnt frame = go 0 frame
  where
    go nb t = mkPure $ \ds a ->
        let nb' = nb + 1
            t'  = t - dtime ds in
        if nb' == cnt && t' > 0
        then (Right a, go 0 frame)
        else (Left (), go nb' t')
