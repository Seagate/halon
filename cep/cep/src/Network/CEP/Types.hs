{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
--
module Network.CEP.Types where

import Data.ByteString (ByteString)
import Data.Dynamic
import GHC.Generics

import           Control.Distributed.Process hiding (catch)
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import qualified Control.Monad.Trans.State.Strict as State
import           Control.Exception (throwIO)
import           Control.Monad.Catch
import           Data.Binary hiding (get, put)
import           Data.Int
import qualified Data.Map as M
import           Data.Set (Set)
import           Data.Monoid ((<>))
import           Data.UUID (UUID)
import           Data.PersistMessage
import           Data.Proxy
import qualified Data.IntPSQ as PSQ
import           Data.Hashable
import qualified Data.ByteString.Lazy as Lazy (ByteString)
import           System.Clock
import           Control.Lens hiding (Index, Setting)

import           Network.CEP.Buffer
import qualified Network.CEP.Log as Log

-- | Application type over which the CEP engine is parametrised.
class Application x where
  type GlobalState x :: *
  type LogType x :: *

data Time = Absolute !TimeSpec
          | Relative !Int
          deriving (Eq, Ord, Show)

instance Monoid Time where
    mempty = Relative 0
    mappend (Relative a) (Relative b) = Relative $ a + b
    mappend (Relative a) (Absolute b) = Absolute $ b + toSecs a
    mappend (Absolute a) (Relative b) = Absolute $ a + toSecs b
    mappend (Absolute a) (Absolute b) = Absolute $ max a b

toSecs :: Int -> TimeSpec
toSecs i = TimeSpec (fromIntegral i) 0

-- | That message is sent when a 'Process' asks for a subscription.
data Subscribe = Subscribe
    { _subType :: !ByteString -- ^ Serialized event type
    , _subPid  :: !ProcessId  -- ^ Subscriber 'ProcessId'
    } deriving (Show, Typeable, Generic)
instance Binary Subscribe

-- | That message is sent when a 'Process' asks to remove a subscription.
data Unsubscribe = Unsubscribe
      { _unsubType :: !ByteString -- ^ Serialized event type
      , _unsubPid  :: !ProcessId  -- ^ Subscriber 'ProcessId'
      } deriving (Show, Typeable, Generic)
instance Binary Unsubscribe

newtype SMId = SMId { getSMId :: Int64 } deriving (Eq, Show, Ord, Num)

-- | Used as a key for referencing a rule at upmost level of the CEP engine.
--   The point is to allow the user to refer to rules by their name while
--   being able to know which rule has been defined the first. That give us
--   prioritization.
data RuleKey = RuleKey
    { _ruleKeyId   :: !Int
    , _ruleKeyName :: !String
    } deriving (Eq, Show, Generic)

instance Binary RuleKey
instance Hashable RuleKey

instance Ord RuleKey where
    compare (RuleKey k1 _) (RuleKey k2 _) = compare k1 k2

initRuleKey :: RuleKey
initRuleKey = RuleKey 0 "init"

data EngineState g = EngineState
   { _engineStateMaxId :: {-# UNPACK #-} !SMId
   , _engineTimestamp   :: {-# UNPACK #-} !TimeSpec
   , _engineEvents      :: !(PSQ.IntPSQ TimeSpec RuleKey)
   , _engineStateGlobal :: !g
   }

makeLenses ''EngineState

nextSmId :: Monad m => State.StateT (EngineState g) m SMId
nextSmId = engineStateMaxId <<%= (+1)

newSubscribeRequest :: forall proxy a. Serializable a
                    => ProcessId
                    -> proxy a
                    -> Subscribe
newSubscribeRequest pid _ = Subscribe bytes pid
  where
    bytes = encodeFingerprint $ fingerprint (undefined :: a)

-- | Emitted every time an event of type @a@ is published. A 'Process' will
---  receive that message only if it subscribed for that type of message.
data Published a = Published
    { pubValue :: !a
      -- ^ Published event.
    , pubPid :: !ProcessId
      -- ^ The emitting process.
    } deriving (Show, Typeable, Generic)

instance Binary a => Binary (Published a)

-- | CEP engine uses typed subscriptions. Subscribers are referenced by their
--   'ProcessId'. Several subscribers can be associated to a type of message.
type Subscribers = M.Map Fingerprint (Set ProcessId)

-- | Logging information passed to SM level.
data SMLogger app l where
  SMLogger :: Application app => {
    sml_logger :: Log.Event (LogType app) -> GlobalState app -> Process ()
  , sml_state_logger :: Maybe (l -> Log.Environment)
  } -> SMLogger app l

-- | Keeps track of time in order to use time varying combinators (FRP).
-- type TimeSession = Session Process (Timed Time ())

-- | Common Netwire 'Wire' type used accross CEP space. It's use for type
--   dependent state machine.
-- type CEPWire a b = Wire (Timed Time ()) () Process a b

-- type SimpleCEPWire a b = Wire (Timed Time ()) () Identity a b

-- | Rule dependent, labeled state machine. 'Phase's are defined within a rule.
--   Phases within an 'Application' of type 'app' are able to handle a global
--   state `GlobalState app` shared with all rules and a local state `l` only
--   available at a rule level.
data Phase app l = Phase
    { _phName :: !String            -- ^ 'Phase' name.
    , _phCall :: !(PhaseCall app l) -- ^ 'Phase' state machine.
    }

-- | Reference to 'Phase'. 'PhaseHandle' are safe to use for retrieving an
--   existing 'Phase' as those are generated by CEP engine itself.
newtype PhaseHandle = PhaseHandle { _phHandle :: String }
  deriving (Eq, Show)

-- | Internal 'Timeout' message.
newtype Timeout = Timeout RuleKey deriving Binary

-- | Pretty sure my colleagues will complain about my naming skill ! It
--   reprensents the way we want to access a resource. It could be a 'Phase'
--   for instance
data Jump a
    = NormalJump a      -- ^ Accesses a resource directly.
    | OnTimeJump Time a -- ^ Jump after some time happened.
    deriving Show

instance Eq a => Eq (Jump a) where
  (NormalJump x) == (NormalJump y) = x == y
  _ == _ = False

instance Functor Jump where
    fmap f (NormalJump a)       = NormalJump $ f a
    fmap f (OnTimeJump t a)     = OnTimeJump t $ f a

-- | Just like 'MonadIO', 'MonadProcess' should satisfy the following
-- laws:
--
-- * @'liftProcess' . 'return' = 'return'@
-- * @'liftProcess' (m >>= f) = 'liftProcess' m >>= ('liftProcess' . f)@
class Monad m => MonadProcess m where
  -- | Lifts a 'Process' computation in the state machine.
  liftProcess  :: Process a -> m a

instance MonadProcess Process where
  liftProcess = Prelude.id

instance MonadProcess (ProgramT (PhaseInstr app l) Process) where
  liftProcess = singleton . Lift

instance MonadThrow (ProgramT (PhaseInstr app l) Process) where
  throwM = liftProcess . liftIO . throwIO

instance MonadCatch (ProgramT (PhaseInstr app l) Process) where
  catch f h = singleton $ Catch f h

normalJump :: a -> Jump a
normalJump = NormalJump

getSnapshotTime :: State.StateT (EngineState g) Process TimeSpec
getSnapshotTime = State.gets _engineTimestamp

addEvent :: RuleKey -> Time -> State.StateT (EngineState g) Process Time
addEvent key t = do
  t' <- case t of
          Absolute k -> return k
          Relative r -> (+) <$> liftIO (getTime Monotonic) <*> pure (toSecs r)
  State.modify $ \e ->
    e{_engineEvents=snd $ PSQ.alter (\mx -> case mx of
         Nothing -> ((), Just (t', key))
         Just (o,_) -> ((), Just (min t' o, key))) (_ruleKeyId key) (_engineEvents e)}
  return (Absolute t')

-- | Jumps to a resource after a certain amount of time.
timeout :: Int -> Jump PhaseHandle -> Jump PhaseHandle
timeout dt (NormalJump a)   = OnTimeJump (mempty <> Relative dt) a
timeout dt (OnTimeJump d a) = OnTimeJump (d <> Relative dt) a

jumpPhaseName :: Jump (Phase app l) -> String
jumpPhaseName (NormalJump p)       = _phName p
jumpPhaseName (OnTimeJump _ p)     = _phName p

jumpPhaseCall :: Jump (Phase app l) -> PhaseCall app l
jumpPhaseCall (NormalJump p)       = _phCall p
jumpPhaseCall (OnTimeJump _ p)     = _phCall p

jumpPhaseHandle :: Jump PhaseHandle -> String
jumpPhaseHandle (NormalJump h)       = _phHandle h
jumpPhaseHandle (OnTimeJump _ h)     = _phHandle h

-- | Update the time of a 'Jump'. If it's ready, gets its value.
jumpApplyTime :: RuleKey -> Jump a -> State.StateT (EngineState g) Process (Either (Jump a) a)
jumpApplyTime _   (NormalJump h)   = return $ Right h
jumpApplyTime key (OnTimeJump p h) = do
   ct <- getSnapshotTime
   case p of
     Absolute wt | ct < wt   -> do p' <- addEvent key p
                                   return $ Left $ OnTimeJump p' h
                 | otherwise -> return $ Right h
     -- no reason why we could appear here, but do the best we could.
     Relative{} -> do
      p' <- addEvent key p
      return $ Left $ OnTimeJump (Absolute ct <> p') h

-- | Applies a 'Jump' tatic to another one without caring about its internal
--   value.
jumpBaseOn :: Jump a -> Jump b -> Jump b
jumpBaseOn (OnTimeJump p _) jmp =
     case jmp of
       OnTimeJump r b -> OnTimeJump (p <> r) b
       NormalJump b   -> OnTimeJump p b
jumpBaseOn _ jmp = jmp

-- | Creates a process that will emit a 'Timeout' message once a 'SimpleWire'
--   will emit a value.
jumpEmitTimeout :: RuleKey -> Jump a -> State.StateT (EngineState g) Process (Jump a)
jumpEmitTimeout key jmp = do
    res <- jumpApplyTime key jmp
    case res of
      Left nxt_jmp ->
        case nxt_jmp of
          (OnTimeJump r b) -> do
              r' <- addEvent key r
              return $ OnTimeJump r' b
          _ -> return nxt_jmp
      Right a -> return (NormalJump a)

-- | CEP 'Engine' state-machine specification. It's about defining rule or set
--   up options that will change the engine behavior.
type Specification s a = Program (Declare s) a

-- | For compability purpose.
type Definitions s a = Specification s a

-- | Type level trick in order to make sure that the last rule state machine
--   instruction is a 'start' call.
data Started app l = StartingPhase l (Jump (Phase app l))

-- | Holds type information used for later type message deserialization.
data TypeInfo = forall a. Serializable a => TypeInfo
    { _typFingerprint :: !Fingerprint
    , _typeProxy      :: !(Proxy a)
    }

instance Eq TypeInfo where
    TypeInfo a _ == TypeInfo b _ = a == b

instance Ord TypeInfo where
    compare (TypeInfo a _) (TypeInfo b _) = compare a b

-- | Internal use only. It uses to know what type of message are expected from
--   'PhaseStep' data constructor.
data Seq
    = Nil
    | forall a. Serializable a =>
      Cons (Proxy a) Seq

-- | Little state machine. It's mainly used to implement combinator like
--   'sequenceIf' for instance.
data PhaseStep a b =
  forall i. Serializable i => Await (i -> PhaseStep a b)
  -- ^ Awaits for more input in order to produce the next state of the
  -- state machine.
  | Emit b
  -- ^ State machine successfully produces a final value.
  | Error
  -- ^ Informs the state machine is in error state. It's mainly used
  -- to implement predicate logic for instance.

-- | When defining a phase that need some type of message in order to proceed,
--   there are several type strategy that will produce that type.
--
-- 'PhaseWire': Await for a message of type @a@ then apply it to
-- Netwire state machine to produce a @b@. This allows to have time
-- varying logic.
--
-- 'PhaseMatch': Await for a @a@ message, if the given predicate
-- returns 'True', pass it to the continuation in order to produce a
-- @b@.
--
-- 'PhaseNone': Simply awaits for a message.
--
-- 'PhaseSeq': Uses 'PhaseStep' state machine in order to produce a
-- @b@ message.
data PhaseType app l a b where
    -- PhaseWire  :: CEPWire a b -> PhaseType g l a b
    PhaseMatch :: Application app
               => (a -> (GlobalState app) -> l ->  Process (Maybe b)) -> PhaseType app l a b
    PhaseNone  :: PhaseType app l a a
    PhaseSeq   :: Seq -> PhaseStep a b -> PhaseType app l a b

-- | 'Phase' state machine type. Either it's a 'ContCall', it needs a message
--   in order to proceed. If it's a 'DirectCall', it can be started right away
data PhaseCall app l
    = DirectCall (PhaseM app l ())
    | forall a b. (Serializable a, Serializable b) =>
      ContCall (PhaseType app l a b) (b -> PhaseM app l ())

-- | Testifies a 'wants' has been made before interacting with a 'Buffer'
data Token a = Token

-- | Possible settings which may be applied at the rule level.
data RuleSetting app l where
  LocalStateLogger :: (l -> Log.Environment) -> RuleSetting app l

-- | Rule state machine.
--
-- 'Start': Starts the rule given a phase and an inital local state value.
--
-- 'NewHandle': Defines a phase handle. By default, that handle would
-- reference a 'Phase' state machine that will ask and do nothing.
--
-- 'SetPhase': Assignes a 'Phase' state machine to the handle.
--
-- 'Wants': Indicates that rule is interested in a particular message.
--
-- 'SetRuleSetting': Sets a rule-level configuration option.
data RuleInstr app l a where
    Start     :: Jump PhaseHandle -> l -> RuleInstr app l (Started app l)
    NewHandle :: String -> RuleInstr app l (Jump PhaseHandle)
    SetPhase  :: Jump PhaseHandle -> (PhaseCall app l) -> RuleInstr app l ()
    Wants :: Serializable a => Proxy a -> RuleInstr app l (Token a)
    SetRuleSetting :: RuleSetting app l -> RuleInstr app l ()

type RuleM app l a = Program (RuleInstr app l) a

-- | Defines a phase handle.
phaseHandle :: String -> RuleM app l (Jump PhaseHandle)
phaseHandle n = singleton $ NewHandle n

-- | Indicates we might be interested by a particular message.
wants :: Serializable a => Proxy a -> RuleM app l (Token a)
wants p = singleton $ Wants p

-- | Set the logger for logging of local state.
setLocalStateLogger :: (l -> Log.Environment) -> RuleM app l ()
setLocalStateLogger logger =
  singleton $ SetRuleSetting $ LocalStateLogger logger

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would be directly
--   executed when triggered.
directly :: Jump PhaseHandle -> PhaseM app l () -> RuleM app l ()
directly h action = singleton $ SetPhase h (DirectCall action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would await for
--   a specific message before starting.
setPhase :: Serializable a
         => Jump PhaseHandle
         -> (a -> PhaseM app l ())
         -> RuleM app l ()
setPhase h action = singleton $ SetPhase h (ContCall PhaseNone action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would await for
--   a specific message before starting. The expected messsage should
--   satisfies the given predicate.
setPhaseIf :: (Application app, Serializable a, Serializable b)
           => Jump PhaseHandle
           -> (a -> GlobalState app -> l -> Process (Maybe b))
           -> (b -> PhaseM app l ())
           -> RuleM app l ()
setPhaseIf h p action = singleton $ SetPhase h (ContCall (PhaseMatch p) action)

-- | Internal use only. Waits for 2 type of messages to come sequentially and
--   apply them to a predicate. If the predicate is statisfied, we yield those
--   value in a tuple, otherwise we switch to the 'Error' state.
__phaseSeq2 :: forall app l a b. (Serializable a, Serializable b)
            => (a -> b -> Bool)
            -> PhaseType app l a (a, b)
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
                => Jump PhaseHandle
                -> (a -> b -> Bool)
                -> (a -> b -> PhaseM app l ())
                -> RuleM app l ()
setPhaseSequenceIf h p t =
    singleton $ SetPhase h (ContCall (__phaseSeq2 p) action)
  where
    action (a,b) = t a b

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that expects 2 types of
--   message to come sequentially.
setPhaseSequence :: (Serializable a, Serializable b)
                 => Jump PhaseHandle
                 -> (a -> b -> PhaseM app l ())
                 -> RuleM app l ()
setPhaseSequence h t =
    setPhaseSequenceIf h (\_ _ -> True) t

-- | Informs CEP engine that rule will start with a particular phase given an
--   initial local state value.
start :: Jump PhaseHandle -> l -> RuleM app l (Started app l)
start h l = singleton $ Start h l

-- | Like 'start' but with a local state set to unit.
start_ :: Jump PhaseHandle -> RuleM app () (Started app ())
start_ h = start h ()

-- | Start a rule with an implicit fork.
startFork :: Jump PhaseHandle -> l -> RuleM app l (Started app l)
startFork rule = startForks [rule]

-- | Start a rule with an implicit fork. Rule may started from
-- different phases.
startForks :: [Jump PhaseHandle] -> l -> RuleM app l (Started app l)
startForks rules state = do
    winit <- initWrapper
    start winit state
  where
    initWrapper = do
      wrapper_init <- phaseHandle "wrapper_init"
      wrapper_clear <- phaseHandle "wrapper_clear"
      wrapper_end <- phaseHandle "wrapper_end"

      directly wrapper_init $ switch (rules ++ [wrapper_clear])

      directly wrapper_clear $ do
        fork NoBuffer $ switch (rules ++ [timeout 60 wrapper_clear])
        continue wrapper_end

      directly wrapper_end stop

      return wrapper_init

type PhaseM app l a = ProgramT (PhaseInstr app l) Process a

-- | Type helper that either references the global or local state of a 'Phase'
--   state machine.
data Scope g l a where
    Global :: Scope g l g
    Local  :: Scope g l l

-- | When forking a new 'Phase' state machine, it possible to either copy
--   parent 'Buffer' or starting with an empty one, another option is to drop
--   all messages that are older than one you work with.
data ForkType = NoBuffer | CopyBuffer | CopyNewerBuffer

-- | 'Phase' state machine.
--
-- 'Continue': Jumps to 'Phase' referenced by that handle.
--
-- 'Get': Gets scoped state from memory.
--
-- 'Put': Updates scoped state in memory.
--
-- 'Stop': Stops the state machine. Has different behavior depending
-- on the the context of the state machine.
--
-- 'Fork': Forks a new 'Phase' state machine.
--
-- 'Lift': Lifts a 'Process' computation in the state machine.
--
-- 'Suspend': Parks the current state machine. Has different behavior
-- depending on state machine context.
--
-- 'Publish': Pushes message to subscribers.
--
-- 'Switch': Changes state machine context. Given the list of
-- 'PhaseHandle', switch to the first 'Phase' that's successfully
-- executed.
--
-- 'Peek': Peeks a message from the 'Buffer' given a minimun 'Index'.
-- The 'Buffer' is not altered.
--
-- 'Shift': Consumes a message from the 'Buffer' given a minimun
-- 'Index'. The 'Buffer' is altered.
--
-- 'Catch': Exception handler.
data PhaseInstr app l a where
    Continue :: Jump PhaseHandle -> PhaseInstr app l a
    Get :: Application app => Scope (GlobalState app) l a -> PhaseInstr app l a
    Put :: Application app => Scope (GlobalState app) l a -> a -> PhaseInstr app l ()
    Stop :: PhaseInstr app l a
    Fork :: ForkType -> PhaseM app l () -> PhaseInstr app l ()
    Lift :: Process a -> PhaseInstr app l a
    Suspend :: PhaseInstr app l ()
    Publish :: Serializable e => e -> PhaseInstr app l ()
    Switch :: [Jump PhaseHandle] -> PhaseInstr app l ()
    Peek :: Serializable a => Index -> PhaseInstr app l (Index, a)
    Shift :: Serializable a => Index -> PhaseInstr app l (Index, a)
    Catch :: Exception e => (PhaseM app l a) -> (e -> PhaseM app l a) -> PhaseInstr app l a
    AppLog :: Application app => LogType app -> PhaseInstr app l ()

-- | Gets scoped state from memory.
get :: Application app => Scope (GlobalState app) l a -> PhaseM app l a
get s = singleton $ Get s

-- | Gets specific component of scoped state from memory.
gets :: Application app
     => Scope (GlobalState app) l a -> (a -> b) -> PhaseM app l b
gets s f = f <$> get s

-- | Updates scoped state in memory.
put :: Application app => Scope (GlobalState app) l a -> a -> PhaseM app l ()
put s a = singleton $ Put s a

-- | Maps and old scoped state in memory.
modify :: Application app
       => Scope (GlobalState app) l a -> (a -> a) -> PhaseM app l ()
modify s k = put s . k =<< get s

-- | Jumps to 'Phase' referenced by given 'PhaseHandle'
continue :: Jump PhaseHandle -> PhaseM app l a
continue p = singleton $ Continue p

-- | Stops the state machine. Depending the current state machine context:
--   - Normal context: State machine stops and is removed from engine, so
--      current invocation of the rule is will not be triggered.
--
--   - Switch context: State machine tries the next alternative 'Phase' without
--     adding back the current state machine to the list of alternatives.
stop :: PhaseM app l a
stop = singleton $ Stop

-- | Stops the state machine. Has different behavior depending on the context
--   of the state machine.
fork :: ForkType -> PhaseM app l () -> PhaseM app l ()
fork typ a = singleton $ Fork typ a

-- | Parks the current state machine. Has different behavior depending on state
--   machine context.
--   - Normal context: State machine is parked.
--   - Switch context: State machine tries the next alternative 'Phase' but
--     adding back the current state machine to the list of alternatives.
suspend :: PhaseM app l ()
suspend = singleton Suspend

-- | Pushes message to subscribers.
publish :: Serializable e => e -> PhaseM app l ()
publish e = singleton $ Publish e

-- | Application log. Log a value in the underlying application log type.
appLog :: Application app => LogType app -> PhaseM app l ()
appLog evt  = singleton $ AppLog evt

-- | Changes state machine context. Given the list of 'PhaseHandle', switch to
--   the first 'Phase' that's successfully executed.
switch :: [Jump PhaseHandle] -> PhaseM app l ()
switch xs = singleton $ Switch xs

-- | Peeks a message from the 'Buffer' given a minimun 'Index'. The 'Buffer' is
--   not altered. If the message is not available, 'Phase' state machine is
--   suspended.
peek :: Serializable a => Token a -> Index -> PhaseM app l (Index, a)
peek _ idx = singleton $ Peek idx

-- | Consumes a message from the 'Buffer' given a minimun 'Index'. The 'Buffer'
--   is altered. If the message is not available, 'Phase' state machine is
--   suspended.
shift :: Serializable a => Token a -> Index -> PhaseM app l (Index, a)
shift _ idx = singleton $ Shift idx

-- | Settings that change CEP engine execution.
--
-- 'Logger': Enables logging.
--
-- 'RuleFinalizer': Sets a rule finalizer.
--
-- 'PhaseBuffer': Sets the default message 'Buffer'.
--
-- 'DebugMode': Sets debug mode.
--
-- 'DefaultHandler': Sets the default handler for 'Message's.
data Setting s a where
    Logger :: Application app => Setting app (Log.Event (LogType app) -> GlobalState app -> Process ())
    RuleFinalizer :: (Application app, g ~ GlobalState app) => Setting app (g -> Process g)
    PhaseBuffer :: Setting s Buffer
    DebugMode :: Setting s Bool
    DefaultHandler :: Application app
                   => Setting app (UUID -> StablePrint -> Lazy.ByteString
                                        -> GlobalState app -> Process ())

-- | Definition state machine.
--
-- 'DefineRule': Defines a new rule.
--
-- 'SetSetting: Set a CEP engine setting.
--
-- 'Init': Set a rule to execute before proceeding regular CEP engine
-- execution.
data Declare app a where
    DefineRule :: String -> RuleM app l (Started app l) -> Declare app ()
    SetSetting :: Setting app a -> a -> Declare app ()
    Init :: RuleM app l (Started app l) -> Declare app ()

-- | Defines a new rule.
define :: String -> RuleM app l (Started app l) -> Specification app ()
define name action = singleton $ DefineRule name action

-- | Set a rule to execute before proceeding regular CEP engine execution. That
--   rule must successfully terminate (Doesn't have 'Phase' state machines
--   waiting on the stack).
initRule :: RuleM app l (Started app l) -> Specification app ()
initRule r = singleton $ Init r

-- | Like 'defineSimpleIf' but with a default predicate that lets
--   anything goes throught.
defineSimple :: (Application app, Serializable a)
             => String
             -> (forall l. a -> PhaseM app l ())
             -> Specification app ()
defineSimple n k = defineSimpleIf n (\e _ -> return $ Just e) k

-- | Shorthand to define a simple rule with a single phase. It defines
--   'PhaseHandle' named @phase-1@, calls 'setPhaseIf' with that handle
--   and then call 'start' with a '()' local state initial value.
defineSimpleIf :: (Application app, Serializable a, Serializable b)
               => String
               -> (a -> (GlobalState app) -> Process (Maybe b))
               -> (forall l. b -> PhaseM app l ())
               -> Specification app ()
defineSimpleIf n p k = define n $ do
    h <- phaseHandle $ n++"-phase"
    setPhaseIf h (\e g _ -> p e g) k
    start h ()

-- | Enables logging by using the given callback. The global state can be read.
setLogger :: Application app
          => (Log.Event (LogType app) -> GlobalState app -> Process ())
          -> Specification app ()
setLogger k = singleton $ SetSetting Logger k

-- | Sets a rule finalizer. A rule finalizer is called after a rule has been
--   executed. A rule finalizer is able to change CEP engine global state.
setRuleFinalizer :: (Application app , g ~ GlobalState app)
                 => (g -> Process g) -> Specification app ()
setRuleFinalizer k = singleton $ SetSetting RuleFinalizer k

-- | Sets the default message 'Buffer'.
setBuffer :: Buffer -> Specification s ()
setBuffer b = singleton $ SetSetting PhaseBuffer b

-- | Enables debug mode.
enableDebugMode :: Specification s ()
enableDebugMode = singleton $ SetSetting DebugMode True

-- | Set a handler for 'PersistMessage's that were not consumed by any other
-- rules.
--
-- Unconsumed raw messages are silently discarded.
setDefaultHandler :: Application app
                  => (UUID -> StablePrint -> Lazy.ByteString -> GlobalState app
                           -> Process ())
                  -> Specification app ()
setDefaultHandler = singleton . SetSetting DefaultHandler

-- | Request runtime information
data RuntimeInfoRequest = RuntimeInfoRequest ProcessId Bool -- mem?
  deriving (Generic, Typeable)

instance Binary RuntimeInfoRequest
