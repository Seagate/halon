{-# LANGUAGE BangPatterns, RankNTypes, ScopedTypeVariables  #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--

module Network.CEP
       ( module Network.CEP.Types
       , runProcessor
       , simpleSubscribe
       , subscribe
       , occursWithin
       ) where

import Prelude hiding ((.), id)
import Data.Monoid

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Wire.Core
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

subscribe :: Serializable a => ProcessId -> Sub a -> CEP s ()
subscribe pid sub = liftProcess $ simpleSubscribe pid sub

runProcessor :: s -> RuleM s () -> Process a
runProcessor s rm = go start clockSession_ (cepRules rs)
  where
    rs = runRuleM rm

    start = initBookkeeping s

    matches = match (return . SubRequest) : cepMatches rs

    go book session wire = do
        msg <- receiveWait matches
        case msg of
          SubRequest sub ->
            let key     = decodeFingerprint $ _subType sub
                value   = _subPid sub
                newMap  = M.insert key value (_subscribers book)
                newBook = book { _subscribers = newMap } in
            go newBook session wire
          Other dyn -> do
            (step, nextSession) <- stepSession session
            let action = stepWire wire step (Right dyn)
            ((_, nextWire), nextBook) <- runCEP action book
            go nextBook nextSession nextWire

initBookkeeping :: s -> Bookkeeping s
initBookkeeping = Bookkeeping M.empty

occursWithin :: Monoid s => Int -> NominalDiffTime -> ComplexEvent s a a
occursWithin cnt frame = go 0 frame
  where
    go nb t = mkPure $ \ds a ->
        let nb' = nb + 1
            t'  = t - dtime ds in
        if nb' == cnt && t' > 0
        then (Right a, go 0 frame)
        else (Left (), go nb' t')
