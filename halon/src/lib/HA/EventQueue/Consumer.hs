{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE Rank2Types          #-}
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
       , setPhaseHAEvent
       , setPhaseHAEventIf
       , defineSimpleHAEvent
       , defineSimpleHAEventIf
       , wantsHAEvent
       , peekHAEvent
       , shiftHAEvent
       ) where

import Prelude hiding ((.), id)

import HA.EventQueue.Types
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable, fingerprint)
-- Qualify all imports of any distributed-process "internals".
import qualified Control.Distributed.Process.Internal.Types as I
    (Message(..), payloadToMessage)
import Data.Binary (decode)
import Data.ByteString (ByteString)
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

-- | Uses to deserialized an incoming 'HAEvent [Bytestring]' to 'HAEvent a'.
--   If the resulted 'HAEvent a' satisfies the predicate then we pass it to the
--   callback and return the result.
haEventPredicate :: forall g l a b. Serializable a
                 => Proxy a
                 -> (HAEvent a -> g -> l -> Process (Maybe b))
                 -> HAEvent [ByteString]
                 -> g -- Global state
                 -> l -- Local state
                 -> Process (Maybe b)
haEventPredicate _ p e g l = do
    let msg     = I.payloadToMessage $ eventPayload e
        decoded = decodeEvent e
    if I.messageFingerprint msg == fingerprint (undefined :: a)
      then p decoded g l
      else return Nothing

-- | Decodes 'HAEvent' payload to requested type value.
decodeEvent :: forall a. Serializable a => HAEvent [ByteString] -> HAEvent a
decodeEvent e@HAEvent{..} =
    let !x = decode $ I.messageEncoding $ I.payloadToMessage eventPayload :: a
    in e{ eventPayload = x }

-- | Takes the first HA event.
expectHAEvent :: forall a. Serializable a => Process (HAEvent a)
expectHAEvent = receiveWait [matchHAEvent return]

-- | Assigns a 'PhaseHandle' to an action that expects a specific 'HAEvent'.
setPhaseHAEvent :: forall a g l. Serializable a
                => PhaseHandle
                -> (HAEvent a -> PhaseM g l ())
                -> RuleM g l ()
setPhaseHAEvent h k = setPhaseHAEventIf h (\e _ _ -> return $ Just e) k

-- | Assigns a 'PhaseHandle' to an action that expects a specific 'HAEvent'. In
--   order for that action to be executed, the expected 'HAEvent' should
--   satisfies the given predicate.
setPhaseHAEventIf :: forall a b g l. (Serializable a, Serializable b)
                  => PhaseHandle
                  -> (HAEvent a -> g -> l -> Process (Maybe b))
                  -> (b -> PhaseM g l ())
                  -> RuleM g l ()
setPhaseHAEventIf h p k = setPhaseMatch h
                          (haEventPredicate (Proxy :: Proxy a) p) k

-- | Like 'defineSimpleHAEventIf' but with a default predicate that lets
--   anything goes throught.
defineSimpleHAEvent :: Serializable a
                    => String
                    -> (forall l. HAEvent a -> PhaseM g l ())
                    -> Definitions g ()
defineSimpleHAEvent n k =
    defineSimpleHAEventIf n (\e _ -> return $ Just e) k

-- | Shorthand to define a simple rule with a single phase. It defines
--   'PhaseHandle' named `phase-1`, calls 'setPhaseHAEventIf' with that handle
--   and then call `start` with a '()' local state initial value.
defineSimpleHAEventIf :: (Serializable a, Serializable b)
                      => String
                      -> (HAEvent a -> g -> Process (Maybe b))
                      -> (forall l. b -> PhaseM g l ())
                      -> Definitions g ()
defineSimpleHAEventIf n p k = define n $ do
    h <- phaseHandle "phase-1"
    setPhaseHAEventIf h (\e g _ -> p e g) k
    start h ()

-- | Type trick that is used to make sure that when the user wants to operate
--   directly on the state-machine 'Buffer' he's already declared its
--   interest on specific type.
wantsHAEvent :: Serializable a => Proxy a -> RuleM g l (Token (HAEvent a))
wantsHAEvent _ = do
    _ <- wants (Proxy :: Proxy (HAEvent [ByteString]))
    return Token

-- | Peeks the first 'HAEvent' with an 'Index' greater than the given one. If
--   exists, this 'HAEvent' will not be removed from the state-machine 'Buffer'.
peekHAEvent :: forall a g l. Serializable a
            => Token (HAEvent a)
            -> Index
            -> PhaseM g l (Index, HAEvent a)
peekHAEvent tok idx = do
    (idx', e) <- peek Token idx
    let msg    = I.payloadToMessage $ eventPayload e
        dec    = decodeEvent e :: HAEvent a
        passed = I.messageFingerprint msg == fingerprint (undefined ::a)
    if passed
        then return (idx', dec)
        else peekHAEvent tok idx'

-- | Gets the first 'HAEvent' with an 'Index' greater than the given one. If
--   exists, this 'HAEvent' WILL be removed from the state-machine 'Buffer'.
shiftHAEvent :: forall a g l. Serializable a
             => Token (HAEvent a)
             -> Index
             -> PhaseM g l (Index, HAEvent a)
shiftHAEvent tok idx = do
    (idx', e) <- peekHAEvent tok idx
    _         <- shift (Token :: Token (HAEvent [ByteString])) (idx' - 1)
    return (idx', e)
