{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- All functions in this module are /only/ used by consumers. The RC is one
-- such consumer.

module HA.EventQueue.Consumer
       ( HAEvent(..)
       , expectHAEvent
       , matchHAEvent
       , matchIfHAEvent
       , defineHAEvent
       , onEveryHAEvent
       ) where

import Prelude hiding ((.), id)

import HA.EventQueue.Types
import Control.Wire
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable, fingerprint)
-- Qualify all imports of any distributed-process "internals".
import qualified Control.Distributed.Process.Internal.Types as I
    (Message(..), payloadToMessage)
import Control.Monad.State.Strict
import Data.Binary (encode, decode)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.ByteString.Lazy.Char8 (pack)
import Data.Dynamic
import Network.CEP

-- | Use this function to get the next event sent by the event queue. Vanilla
-- 'expect' cannot be used due to wrapping of event messages into a value of
-- 'HAEvent' type.
--
-- This function is only used by a consumer of the event queue (the RC), not
-- writers.
matchHAEvent :: forall a b. Serializable a
             => (HAEvent a -> Process b)
             -> Match b
matchHAEvent = matchIfHAEvent (const True)

-- | Like 'matchHAEvent' but only takes events satisfying a given predicate.
matchIfHAEvent :: forall a b. Serializable a
               => (HAEvent a -> Bool)
               -> (HAEvent a -> Process b)
               -> Match b
matchIfHAEvent p f =
    matchIf
        (\e -> let msg = I.payloadToMessage (eventPayload e)
                   decoded = decodeEvent e
               in I.messageFingerprint msg == fingerprint (undefined :: a) && p decoded)
        (\e -> f $ decodeEvent e)
  where
    decodeEvent e@HAEvent{..} =
        let !x = decode $ I.messageEncoding $ I.payloadToMessage eventPayload :: a
        in e{ eventPayload = x }

-- | Takes the first HA event.
expectHAEvent :: forall a. Serializable a => Process (HAEvent a)
expectHAEvent = receiveWait [matchHAEvent return]

defineHAEvent :: forall a b s. (Serializable a, Serializable b)
              => ByteString
              -> ComplexEvent s (HAEvent a) b
              -> (b -> CEP s ())
              -> RuleM s ()
defineHAEvent n w k = do
    let m       = matchHAEvent $ \(x :: HAEvent a) -> return $ Other $ toDyn x
        rule    = observe . (id &&& w) . dynEvent
        observe = mkGen_ $ \(hae, b) -> do
          k b
          lgs <- getLogs
          resetLogs
          return $ Right $ Handled
                           { handledRuleId = n
                           , handledInputs = generateHAEventInputs hae b
                           , handledLogs   = lgs
                           , handledValue  = hae { eventPayload = toDyn $ eventPayload hae }
                           }

    modify $ addRule m rule

onEveryHAEvent :: (HAEvent Dynamic -> s -> Process s) -> RuleM s ()
onEveryHAEvent = finishedBy

generateHAEventInputs :: forall a b. (Serializable a, Serializable b)
                      => HAEvent a
                      -> b
                      -> Lazy.ByteString
generateHAEventInputs hae b =
    "eventId="                    <>
    (renderEventId $ eventId hae) <>
    ";eventHops="                 <>
    renderHops (eventHops hae)    <>
    ";"                           <>
    rest
  where
    rest =
        case (eqT :: Maybe (HAEvent a :~: b)) of
          Nothing -> "rule-output=" <> encode b
          _       -> ""

renderEventId :: EventId -> Lazy.ByteString
renderEventId = pack . show

renderHops :: [ProcessId] -> Lazy.ByteString
renderHops xs = pack $ show xs
