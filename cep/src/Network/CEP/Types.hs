{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
--
module Network.CEP.Types where

import Data.Dynamic
import GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad.Operational
import Control.Wire (NominalDiffTime, Timed, Wire)
import Data.Binary hiding (get, put)

import Network.CEP.Buffer

-- | Typelevel trick. It's very similar to `Data.Proxy`. It's use to declare
--   a new subscription.
data Sub a = Sub deriving (Generic, Typeable)

asSub :: a -> Sub a
asSub _ = Sub

instance Binary a => Binary (Sub a)

-- | Simplest Netwire 'Wire' type used accross CEP space. It's use for type
--   dependent state machine.
type CEPWire a b = Wire (Timed NominalDiffTime ()) () Process a b

-- | Rule dependent, labeled state machine. 'Phase's are defined withing a rule.
--   'Phase's are able to handle a global state `g` shared with all rules and a
--   local state `l` only available at a rule level.
data Phase g l =
    Phase
    { _phName :: !String
      -- ^ 'Phase' name.
    , _phCall :: !(PhaseCall g l)
      -- ^ 'Phase' state machine.
    }

-- | Reference to 'Phase'. 'PhaseHandle' are safe to use for retrieving an
--   existing 'Phase' as those are generated by CEP engine itself.
newtype PhaseHandle = PhaseHandle { _phHandle :: String }

-- | CEP engine definition state machine. It's about defining rule or set
--   up options that will change the engine behavior.
type Definitions s a = Program (Declare s) a

-- | Type level trick in order to make sure that the last rule state machine
--   instruction is a 'start' call.
data Started g l = StartingPhase l (Phase g l)

-- | Internal use only. It uses to know what type of message are expected from
--   'PhaseStep' data constructor.
data Seq
    = Nil
    | forall a. Serializable a =>
      Cons (Proxy a) Seq

-- | Little state machine. It's mainly used to implement combinator like
--   'sequenceIf' for instance.
data PhaseStep a b where
    Await :: Serializable i => (i -> PhaseStep a b) -> PhaseStep a b
    -- ^ Awaits for more input in order to produce the next state of the state
    --   machine.
    Emit  :: b -> PhaseStep a b
    -- ^ State machine successfully produces a final value.
    Error :: PhaseStep a b
    -- ^ Informs the state machine is in error state. It's mainly used to
    --   implement predicate logic for instance.

-- | When defining a phase that need some type of message in order to proceed,
--   there are several type strategy that will produce that type.
data PhaseType a b where
    PhaseWire  :: CEPWire a b -> PhaseType a b
    -- ^ Await for a message of type `a` then apply it to Netwire state machine
    --   to produce a `b`. This allows to have time varying logic.
    PhaseMatch :: (a -> Bool) -> (a -> Process b) -> PhaseType a b
    -- ^ Await for a `a` message, if the given predicate returns 'True',
    --   pass it to the continuation in order to produce a `b`.
    PhaseNone  :: PhaseType a a
    -- ^ Simply awaits for a message.
    PhaseSeq   :: Seq -> PhaseStep a b -> PhaseType a b
    -- ^ Uses 'PhaseStep' state machine in order to produce a `b` message.

-- | 'Phase' state machine type. Either it's a 'ContCall', it needs a message
--   in order to proceed. If it's a 'DirectCall', it can be started right away
data PhaseCall g l
    = DirectCall (PhaseM g l ())
    | forall a b. (Serializable a, Serializable b) =>
      ContCall (PhaseType a b) (b -> PhaseM g l ())

-- | Rule state machine.
data RuleInstr g l a where
    Start     :: PhaseHandle -> l -> RuleInstr g l (Started g l)
    -- ^ Starts the rule given a phase and an inital local state value.
    NewHandle :: String -> RuleInstr g l PhaseHandle
    -- ^ Defines a phase handle. By default, that handle would reference a
    --   'Phase' state machine that will ask and do nothing.
    SetPhase  :: PhaseHandle -> (PhaseCall g l) -> RuleInstr g l ()
    -- ^ Assignes a 'Phase' state machine to the handle.

type RuleM g l a = Program (RuleInstr g l) a

-- | Defines a phase handle.
phaseHandle :: String -> RuleM g l PhaseHandle
phaseHandle n = singleton $ NewHandle n

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would be directly
--   executed when triggered.
directly :: PhaseHandle -> PhaseM g l () -> RuleM g l ()
directly h action = singleton $ SetPhase h (DirectCall action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would await for
--   a specific message before starting.
setPhase :: Serializable a
         => PhaseHandle
         -> (a -> PhaseM g l ())
         -> RuleM g l ()
setPhase h action = singleton $ SetPhase h (ContCall PhaseNone action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would require the
--   Netwire state machine to yield a value in order to start.
setPhaseWire :: (Serializable a, Serializable b)
             => PhaseHandle
             -> CEPWire a b
             -> (b -> PhaseM g l ())
             -> RuleM g l ()
setPhaseWire h w action = singleton $ SetPhase h (ContCall (PhaseWire w) action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would wait for
--   type of message to conform the given predicate in order to produce the
--   value needed to start.
setPhaseMatch :: (Serializable a, Serializable b)
              => PhaseHandle
              -> (a -> Bool)
              -> (a -> Process b)
              -> (b -> PhaseM g l ())
              -> RuleM g l ()
setPhaseMatch h p t action =
    singleton $ SetPhase h (ContCall (PhaseMatch p t) action)

-- | Internal use only. Waits for 2 type of messages to come sequentially and
--   apply them to a predicate. If the predicate is statisfied, we yield those
--   value in a tuple, otherwise we switch to the 'Error' state.
__phaseSeq2 :: forall a b. (Serializable a, Serializable b)
            => (a -> b -> Bool)
            -> PhaseType a (a, b)
__phaseSeq2 p = PhaseSeq sq action
  where
    sq = Cons (Proxy :: Proxy a) (Cons (Proxy :: Proxy b) Nil)
    action = Await $ \a ->
             Await $ \b ->
             if p a b
             then Emit (a,b)
             else Error

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that expects 2 types of
--   message to come sequentially. If the predicate is satisfied, we can start.
setPhaseSequenceIf :: (Serializable a, Serializable b)
                => PhaseHandle
                -> (a -> b -> Bool)
                -> (a -> b -> PhaseM g l ())
                -> RuleM g l ()
setPhaseSequenceIf h p t =
    singleton $ SetPhase h (ContCall (__phaseSeq2 p) action)
  where
    action (a,b) = t a b

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that expects 2 types of
--   message to come sequentially.
setPhaseSequence :: (Serializable a, Serializable b)
                 => PhaseHandle
                 -> (a -> b -> PhaseM g l ())
                 -> RuleM g l ()
setPhaseSequence h t =
    setPhaseSequenceIf h (\_ _ -> True) t

-- | Informs CEP engine that rule will start with a particular phase given an
--   initial local state value.
start :: PhaseHandle -> l -> RuleM g l (Started g l)
start h l = singleton $ Start h l

type PhaseM g l a = ProgramT (PhaseInstr g l) Process a

-- | Type helper that either references the global or local state of a 'Phase'
--   state machine.
data Scope g l a where
    Global :: Scope g l g
    Local  :: Scope g l l

-- | When forking a new 'Phase' state machine, it possible to either copy
--   parent 'Buffer' or starting with an empty one.
data ForkType = NoBuffer | CopyBuffer

-- | 'Phase' state machine.
data PhaseInstr g l a where
    Continue :: PhaseHandle -> PhaseInstr g l ()
    -- ^ Jumps to 'Phase' referenced by that handle.
    Save :: g -> PhaseInstr g l ()
    -- ^ Persists the global state.
    Load :: PhaseInstr g l g
    -- ^ Loads global state from a persistent storage.
    Get :: Scope g l a -> PhaseInstr g l a
    -- ^ Gets scoped state from memory.
    Put :: Scope g l a -> a -> PhaseInstr g l ()
    -- ^ Updates scoped state in memory.
    Stop :: PhaseInstr g l a
    -- ^ Stops the state machine. Has different behavior depending on the
    --   the context of the state machine.
    Fork :: ForkType -> PhaseM g l () -> PhaseInstr g l ()
    -- ^ Forks a new 'Phase' state machine.
    Lift :: Process a -> PhaseInstr g l a
    -- ^ Lifts a 'Process' computation in the state machine.
    Suspend :: PhaseInstr g l ()
    -- ^ Parks the current state machine. Has different behavior depending on
    --   state machine context.
    Publish :: Serializable e => e -> PhaseInstr g l ()
    -- ^ Pushes message to subscribers.
    PhaseLog :: String -> String -> PhaseInstr g l ()
    -- ^ Simple log. First parameter is the context and the last one is the
    --   log.
    Switch :: [PhaseHandle] -> PhaseInstr g l ()
    -- ^ Changes state machine context. Given the list of 'PhaseHandle', switch
    --   to the first 'Phase' that's successfully executed.

-- | Persists the global state.
save :: g -> PhaseM g l ()
save g = singleton $ Save g

-- | Loads global state from memory.
load :: PhaseM g l g
load = singleton Load

-- | Gets scoped state from memory.
get :: Scope g l a -> PhaseM g l a
get s = singleton $ Get s

-- | Updates scoped state in memory.
put :: Scope g l a -> a -> PhaseM g l ()
put s a = singleton $ Put s a

-- | Maps and old scoped state in memory.
modify :: Scope g l a -> (a -> a) -> PhaseM g l ()
modify s k = put s . k =<< get s

-- | Jumps to 'Phase' referenced by given 'PhaseHandle'
continue :: PhaseHandle -> PhaseM g l ()
continue p = singleton $ Continue p

-- | Stops the state machine. Depending the current state machine context:
--   - Normal context: State machine just stops.

--   - Switch context: State machine tries the next alternative 'Phase' without
--     adding back the current state machine to the list of alternatives.
stop :: PhaseM g l a
stop = singleton $ Stop

-- | Lifts a 'Process' computation in the state machine.
liftProcess :: Process a -> PhaseM g l a
liftProcess m = singleton $ Lift m

-- | Stops the state machine. Has different behavior depending on the context
--   of the state machine.
fork :: ForkType -> PhaseM g l () -> PhaseM g l ()
fork typ a = singleton $ Fork typ a

-- | Parks the current state machine. Has different behavior depending on state
--   machine context.
--   - Normal context: State machine is parked.
--   - Switch context: State machine tries the next alternative 'Phase' but
--     adding back the current state machine to the list of alternatives.
suspend :: PhaseM g l ()
suspend = singleton Suspend

-- | Pushes message to subscribers.
publish :: Serializable e => e -> PhaseM g l ()
publish e = singleton $ Publish e

-- | Simple log. First parameter is the context and the last one is the log.
phaseLog :: String -> String -> PhaseM g l ()
phaseLog ctx line = singleton $ PhaseLog ctx line

-- | Changes state machine context. Given the list of 'PhaseHandle', switch to
--   the first 'Phase' that's successfully executed.
switch :: [PhaseHandle] -> PhaseM g l ()
switch xs = singleton $ Switch xs

-- | Gathers all the logs produced during 'Phase' state machine run.
data Logs =
    Logs
    { logsRuleName :: !String
      -- ^ Rule name associated with those logs.
    , logsPhaseEntries :: ![(String, String, String)]
      -- ^ Each entry is compound of 'Phase' name, a context and a log value.
    } deriving (Show, Typeable, Generic)

instance Binary Logs

-- | Settings that change CEP engine execution.
data Setting s a where
    Logger :: Setting s (Logs -> s -> Process ())
    -- ^ Enables logging.
    RuleFinalizer :: Setting s (s -> Process s)
    -- ^ Sets a rule finalizer.
    PhaseBuffer :: Setting s Buffer
    -- ^ Sets the default message 'Buffer'.
    DebugMode :: Setting s Bool
    -- ^ Sets debug mode.

-- | Definition state machine.
data Declare g a where
    DefineRule :: String -> RuleM g l (Started g l) -> Declare g ()
    -- ^ Defines a new rule.
    SetSetting :: Setting g a -> a -> Declare g ()
    -- ^ Set a CEP engine setting.

-- | Defines a new rule.
define :: String -> RuleM g l (Started g l) -> Definitions g ()
define name action = singleton $ DefineRule name action


defineSimple :: Serializable a
             => String
             -> (forall l. a -> PhaseM g l ())
             -> Definitions g ()
defineSimple n k = define n $ do
    h <- phaseHandle "phase-1"
    setPhase h k
    start h ()

-- | Enables logging by using the given callback. The global state can be read.
setLogger :: (Logs -> s -> Process ()) -> Definitions s ()
setLogger k = singleton $ SetSetting Logger k

-- | Sets a rule finalizer. A rule finalizer is called after a rule has been
--   executed. A rule finalizer is able to change CEP engine global state.
setRuleFinalizer :: (s -> Process s) -> Definitions s ()
setRuleFinalizer k = singleton $ SetSetting RuleFinalizer k

-- | Sets the default message 'Buffer'.
setBuffer :: Buffer -> Definitions s ()
setBuffer b = singleton $ SetSetting PhaseBuffer b

-- | Enable debug mode.
enableDebugMode :: Definitions s ()
enableDebugMode = singleton $ SetSetting DebugMode True
