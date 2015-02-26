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
       ) where

import Prelude hiding ((.))

import HA.EventQueue.Types
import Control.Wire
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable, fingerprint)
-- Qualify all imports of any distributed-process "internals".
import qualified Control.Distributed.Process.Internal.Types as I
    (Message(..), payloadToMessage)
import Control.Monad.State.Strict
import Data.Binary (decode)
import Data.Dynamic
import Network.CEP hiding (decoded)

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

defineHAEvent :: forall a b s. (Monoid s, Serializable a)
              => ComplexEvent s (HAEvent a) b
              -> (b -> CEP s ())
              -> RuleM s ()
defineHAEvent w k = do
    let m       = matchHAEvent $ \(x :: HAEvent a) -> return $ Other $ toDyn x
        rule    = observe . w . dynEvent
        observe = mkGen_ $ \b -> do
          k b
          return $ Right ()

    modify $ addRule m rule
