{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
--
module Network.CEP.Types where

import           Prelude hiding ((.))
import           Data.ByteString
import           Data.Dynamic
import qualified Data.MultiMap as M
import           GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad.State.Strict
import Control.Wire
import Data.Binary
import Data.MultiMap

-- | Typelevel trick. It's very similar to `Data.Proxy`. It's use to declare
--   a new subscription.
data Sub a = Sub deriving (Generic, Typeable)

instance Binary a => Binary (Sub a)

-- | Only used internally. Hold the event handled by a CEP processor.
data Handled = forall a. Typeable a => Handled a

-- | Only used internally. Currently CEP either handles subscription request or
--   user defined events. Subcription is handled automatically by CEP.
data Msg
    = SubRequest Subscribe
    | Other Dynamic

-- | Data holded by the Rule monad.
data RuleState s =
    RuleState
    { cepMatches :: ![Match Msg]
      -- ^ A list of `Control.Distributed.Process.Match`, that list is
      --   constructed automatically by the library.
    , cepRules :: !(ComplexEvent s Dynamic Handled)
      -- ^ The rule to apply when an event is sent to a CEP processor.
    , cepFinalizers :: (s -> Process s)
      -- ^ A function that is called after an event has been processed by
      --   a rule.
    , cepSpes :: forall a. Typeable a => a -> s -> Process s
      -- ^ A specialized finalizer. It's called when a particular type of event
      --   has been processed by a rule. That's finalizer is called after 'cepFinalizers'
    }

-- | The Rule monad.
newtype RuleM s a = RuleM (State (RuleState s) a)
    deriving (Functor, Applicative, Monad, MonadState (RuleState s))

-- | The CEP monad. 'CEP' is exposed to the user. However, we don't exposed CEP
--   internals state, only user-defined state.
newtype CEP s a = CEP (StateT (Bookkeeping s) Process a)
                  deriving (Functor, Applicative, Monad, MonadIO)

instance MonadState s (CEP s) where
    get = CEP $ gets _state

    put s = CEP $ modify $ \b -> b { _state = s }

type ComplexEvent s a b = Wire (Timed NominalDiffTime ()) () (CEP s) a b

-- | Holds internal CEP data and user-defined state.
data Bookkeeping s =
    Bookkeeping
    { _subscribers :: !(MultiMap Fingerprint ProcessId)
      -- ^ a 'MultiMap' of every 'ProcessId' that subscribed to a specific
      --   event's type.
    , _state :: !s
      -- ^ User-defined state.
    }

-- | That message is sent when a 'Process' asks for a subscription. Used
--   internally.
data Subscribe =
    Subscribe
    { _subType :: !ByteString
      -- ^ Serialized event type.
    , _subPid  :: !ProcessId
      -- ^ Subscriber 'ProcessId'
    } deriving (Show, Typeable, Generic)

instance Binary Subscribe

-- | That message is emitted every time an event of type `a` has been published.
--   A 'Process' will received that message only if it subscribed for that
--   type of message. In CEP parlance, that message will be emitted if that
--   has been processed by the CEP processor or if that processor published it
--   manually (using 'publish' function).
data Published a =
    Published
    { pubValue :: !a
      -- ^ Published event.
    , pubPid   :: !ProcessId
      -- ^ The 'Process' that emitted this publication.
    } deriving (Show, Typeable, Generic)

instance Binary a => Binary (Published a)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------
-- | Publishes a event. Every subscribers of this event's type will receive a
--   'Published a' message.
publish :: Serializable a => a -> CEP s ()
publish a = CEP $ do
    subs <- gets _subscribers
    self <- lift getSelfPid
    let sub = asSub a
        key = fingerprint sub

    lift $ forM_ (M.lookup key subs) $ \pid ->
      send pid (Published a self)

liftProcess :: Process a -> CEP s a
liftProcess m = CEP $ lift m

-- | Add a new finalizer to be performed every time a rule has been executed.
--   That function doesn't replace a previous finalizer. It will be called
--   right after a previous finalizer.
addRuleFinalizer :: (s -> Process s) -> RuleM s ()
addRuleFinalizer = modify . addFinalizer

-- | Defines a new rule. A Rule consists on a 'ComplexEvent' and a handler that
--   will be called if `ComplexEvent` emits something. A 'ComplexEvent' can be
--   seen as state machine that also depends on time.
define :: forall a b s. (Serializable a, Typeable b)
       => ComplexEvent s a b
       -> (b -> CEP s ())
       -> RuleM s ()
define w k = do
    let m       = match $ \(x :: a) -> return $ Other $ toDyn x
        rule    = observe . w . dynEvent
        observe = mkGen_ $ \b -> do
          k b
          return $ Right $ Handled b

    modify $ addRule m rule

-- | Add a new specialized finalizer to be performed every time a specific
--   event's type has been process by a rule. That finalizer will always be
--   performed after a regular finalizer.
finishedBy :: Typeable a => (a -> s -> Process s) -> RuleM s ()
finishedBy = modify . addSpecialized

--------------------------------------------------------------------------------
asSub :: a -> Sub a
asSub _ = Sub

runCEP :: CEP s a -> Bookkeeping s -> Process (a, Bookkeeping s)
runCEP (CEP m) s = runStateT m s

getUsrState :: CEP s s
getUsrState = CEP $ gets _state

setUsrState :: s -> CEP s ()
setUsrState s = CEP $ modify (\b -> b { _state = s})

initRuleState :: RuleState s
initRuleState = RuleState
                { cepMatches    = []
                , cepRules      = mkEmpty
                , cepFinalizers = return
                , cepSpes       = \_ s -> return s
                }

runRuleM :: RuleM s a -> RuleState s
runRuleM (RuleM m) = execState m initRuleState

addRule :: Match Msg
        -> ComplexEvent s Dynamic Handled
        -> RuleState s
        -> RuleState s
addRule m r s =
    s { cepMatches = cepMatches s ++ [m]
      , cepRules   = cepRules s <|> r
      }

composeSpe :: Typeable b
           => (forall a. Typeable a => a -> s -> Process s)
           -> (b -> s -> Process s)
           -> (forall a. Typeable a => a -> s -> Process s)
composeSpe pk k r s = do
    s' <- pk r s
    case cast r of
      Just b -> k b s'
      _      -> return s'

dynEvent :: Serializable a => ComplexEvent s Dynamic a
dynEvent = mkGen_ $ \dyn ->
    case fromDynamic dyn of
      Just a -> Right a <$ publish a
      _      -> return $ Left ()

addFinalizer :: (s -> Process s) -> RuleState s -> RuleState s
addFinalizer p s = s { cepFinalizers = cepFinalizers s >=> p }

addSpecialized :: Typeable a
               => (a -> s -> Process s)
               -> RuleState s
               -> RuleState s
addSpecialized k rs = rs { cepSpes = composeSpe (cepSpes rs) k }
