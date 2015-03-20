-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- Complex Event Processing API
-- It builds a 'Process' out of rules defined by the user. It also support
-- pub/sub feature.

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

-- | Subscribes for a specific type of event. Every time that event occures,
--   this 'Process' will receive a 'Published a' message.
simpleSubscribe :: Serializable a => ProcessId -> Sub a -> Process ()
simpleSubscribe pid sub = do
    self <- getSelfPid
    let key  = fingerprint sub
        fgBs = encodeFingerprint key
    send pid (Subscribe fgBs self)

subscribe :: Serializable a => ProcessId -> Sub a -> CEP s ()
subscribe pid sub = liftProcess $ simpleSubscribe pid sub

-- | Builds a 'Process' out of user-defined rules. That 'Process' will run
-- until the end of the Universe, unless an error occurs in the meantime.
runProcessor :: s -> RuleM s () -> Process a
runProcessor s rm = go start clockSession_ (cepRules rs)
  where
    rs = runRuleM rm

    fin = cepFinalizers rs

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
            ((resp, nextWire), nextBook) <- runCEP action book
            newS <- case resp of
              Right (Handled evt) -> do
                ss <- fin $ _state nextBook
                cepSpes rs evt ss
              _       -> return $ _state nextBook
            go nextBook { _state = newS } nextSession nextWire

initBookkeeping :: s -> Bookkeeping s
initBookkeeping = Bookkeeping M.empty

-- | @occursWithin n t@ Lets through an event every time it occurs @n@ times
--   within @t@ seconds.
occursWithin :: Monoid s => Int -> NominalDiffTime -> ComplexEvent s a a
occursWithin cnt frame = go 0 frame
  where
    go nb t = mkPure $ \ds a ->
        let nb' = nb + 1
            t'  = t - dtime ds in
        if nb' == cnt && t' > 0
        then (Right a, go 0 frame)
        else (Left (), go nb' t')
