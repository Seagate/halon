{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
--
module Network.CEP.Types where

import Data.ByteString (ByteString)
import Data.Dynamic
import GHC.Generics

import           Control.Distributed.Process hiding (catch)
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import           Control.Exception (throwIO)
import           Control.Monad.Catch
import           Control.Wire hiding ((.), loop)
import           Data.Binary hiding (get, put)
import qualified Data.Sequence as S
import           Data.Int
import qualified Data.Map as M
import           Data.Set (Set)
import           Data.UUID (UUID)
import           Data.PersistMessage
import qualified Data.ByteString.Lazy as Lazy (ByteString)
import           System.Clock
import           Control.Lens.TH

import Network.CEP.Buffer

newtype Time = Time TimeSpec deriving (Eq, Ord, Num, Show)

instance Monoid Time where
    mempty = Time 0

    mappend (Time a) (Time b) = Time (a + b)

instance Real Time where
    toRational (Time i) = toRational $ timeSpecAsNanoSecs i

diffTime :: Time -> Time -> Time
diffTime (Time a) (Time b) = Time (diffTimeSpec a b)

systemClockSession :: Session Process (Timed Time ())
systemClockSession = go <*> pure ()
  where
    go =  Session $ do
      t0 <- liftIO $ getTime Monotonic
      return (Timed mempty, loop $ Time t0)

    loop (Time t') = Session $ do
      t <- liftIO $ getTime Monotonic
      let !dt = diffTimeSpec t t'
      return (Timed $ Time dt, loop $ Time t)

-- | That message is sent when a 'Process' asks for a subscription.
data Subscribe =
    Subscribe
    { _subType :: ! ByteString
      -- ^ Serialized event type.
    , _subPid :: !ProcessId
      -- ^ Subscriber 'ProcessId'
    } deriving (Show, Typeable, Generic)

instance Binary Subscribe

-- | That message is sent when a 'Process' asks to remove a subscription.
data Unsubscribe =
      Unsubscribe
      { _unsubType :: !ByteString -- ^ Serialized event type
      , _unsubPid  :: !ProcessId  -- ^ Subscribe 'ProcessId'
      } deriving (Show, Typeable, Generic)
instance Binary Unsubscribe

newtype SMId = SMId { getSMId :: Int64 } deriving (Eq, Show, Ord, Num)

data EngineState g = EngineState
   { _engineStateMaxId :: {-# UNPACK #-} !SMId
   , _engineStateGlobal :: !g
   }

makeLenses ''EngineState

-- | Used as a key for referencing a rule at upmost level of the CEP engine.
--   The point is to allow the user to refer to rules by their name while
--   being able to know which rule has been defined the first. That give us
--   prioritization.
data RuleKey =
    RuleKey
    { _ruleKeyId   :: !Int
    , _ruleKeyName :: !String
    } deriving (Show, Generic)

instance Binary RuleKey

instance Eq RuleKey where
    RuleKey k1 _ == RuleKey k2 _ = k1 == k2

instance Ord RuleKey where
    compare (RuleKey k1 _) (RuleKey k2 _) = compare k1 k2

initRuleKey :: RuleKey
initRuleKey = RuleKey 0 "init"

newSubscribeRequest :: forall proxy a. Serializable a
                    => ProcessId
                    -> proxy a
                    -> Subscribe
newSubscribeRequest pid _ = Subscribe bytes pid
  where
    bytes = encodeFingerprint $ fingerprint (undefined :: a)

-- | Emitted every time an event of type @a@ is published. A 'Process' will
---  receive that message only if it subscribed for that type of message.
data Published a =
    Published
    { pubValue :: !a
      -- ^ Published event.
    , pubPid :: !ProcessId
      -- ^ The emitting process.
    } deriving (Show, Typeable, Generic)

instance Binary a => Binary (Published a)

-- | CEP engine uses typed subscriptions. Subscribers are referenced by their
--   'ProcessId'. Several subscribers can be associated to a type of message.
type Subscribers = M.Map Fingerprint (Set ProcessId)

type SMLogs = S.Seq (String, String, String)

-- | Keeps track of time in order to use time varying combinators (FRP).
type TimeSession = Session Process (Timed Time ())

-- | Common Netwire 'Wire' type used accross CEP space. It's use for type
--   dependent state machine.
type CEPWire a b = Wire (Timed Time ()) () Process a b

type SimpleCEPWire a b = Wire (Timed Time ()) () Identity a b

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
  deriving (Eq, Show)

-- | Internal 'Timeout' message.
newtype Timeout = Timeout RuleKey deriving Binary

-- | Pretty sure my colleagues will complain about my naming skill ! It
--   reprensents the way we want to access a resource. It could be a 'Phase'
--   for instance
data Jump a
    = NormalJump a
      -- ^ Accesses a resource directly.
    | ReactiveJump TimeSession (SimpleCEPWire () ()) a
      -- ^ Accesses a resource only when its 'SimpleWire' advises to do it. A
      --   a 'SimpleWire' is used in order to express a wider set of time
      --   restricted predicate.

instance Eq a => Eq (Jump a) where
  (NormalJump x) == (NormalJump y) = x == y
  (ReactiveJump _ _ x) == (ReactiveJump _ _ y) = x == y
  _ == _ = False

instance Show a => Show (Jump a) where
  show (NormalJump x) = show x
  show (ReactiveJump _ _ x) = "timeout " ++ show x

instance Functor Jump where
    fmap f (NormalJump a)       = NormalJump $ f a
    fmap f (ReactiveJump c w a) = ReactiveJump c w $ f a

-- | Just like 'MonadIO', 'MonadProcess' should satisfy the following
-- laws:
--
-- * @'liftProcess' . 'return' = 'return'@
-- * @'liftProcess' (m >>= f) = 'liftProcess' m >>= ('liftProcess' . f)@
class MonadProcess m where
  -- | Lifts a 'Process' computation in the state machine.
  liftProcess  :: Process a -> m a

instance MonadProcess Process where
  liftProcess = Prelude.id

instance MonadProcess (ProgramT (PhaseInstr g l) Process) where
  liftProcess = singleton . Lift

instance MonadThrow (ProgramT (PhaseInstr g l) Process) where
  throwM = liftProcess . liftIO . throwIO

instance MonadCatch (ProgramT (PhaseInstr g l) Process) where
  catch f h = singleton $ Catch f h

normalJump :: a -> Jump a
normalJump = NormalJump

-- | Jumps to a resource after a certain amount of time.
timeout :: Int -> Jump PhaseHandle -> Jump PhaseHandle
timeout dt (NormalJump a) =
    ReactiveJump systemClockSession (after $ toSecs dt) a
timeout dt (ReactiveJump c w a) =
    ReactiveJump c (w <> after (toSecs dt)) a

toSecs :: Int -> Time
toSecs i = Time $ TimeSpec (fromIntegral i) 0

jumpPhaseName :: Jump (Phase g l) -> String
jumpPhaseName (NormalJump p)       = _phName p
jumpPhaseName (ReactiveJump _ _ p) = _phName p

jumpPhaseCall :: Jump (Phase g l) -> PhaseCall g l
jumpPhaseCall (NormalJump p)       = _phCall p
jumpPhaseCall (ReactiveJump _ _ p) = _phCall p

jumpPhaseHandle :: Jump PhaseHandle -> String
jumpPhaseHandle (NormalJump h)       = _phHandle h
jumpPhaseHandle (ReactiveJump _ _ h) = _phHandle h

-- | Update the time of a 'Jump'. If it's ready, gets its value.
jumpApplyTime :: Jump a -> Process (Either (Jump a) a)
jumpApplyTime (NormalJump h)       = return $ Right h
jumpApplyTime (ReactiveJump c w h) = do
    (t, nxt_c) <- stepSession c
    let (res, nxt) = runIdentity $ stepWire w t (Right ())
    case res of
      Left _ -> return $ Left $ ReactiveJump nxt_c nxt h
      _      -> return $ Right h

-- | Applies a 'Jump' tatic to another one without caring about its internal
--   value.
jumpBaseOn :: Jump a -> Jump b -> Jump b
jumpBaseOn (ReactiveJump c w _) jmp =
    case jmp of
      ReactiveJump _ v b -> ReactiveJump c (w <> v) b
      NormalJump b       -> ReactiveJump c w b
jumpBaseOn _ jmp = jmp

-- | Creates a process that will emit a 'Timeout' message once a 'SimpleWire'
--   will emit a value.
jumpEmitTimeout :: RuleKey -> Jump a -> Process (Jump a)
jumpEmitTimeout key jmp = do
    res <- jumpApplyTime jmp
    case res of
      Left nxt_jmp ->
        case nxt_jmp of
          ReactiveJump s_sess w _ -> do
            self <- getSelfPid
            let action c_sess cur_w = do
                  (c_t, nxt_sess) <- stepSession c_sess
                  let (c_res, nxt_w) = runIdentity $ stepWire cur_w c_t (Right ())
                  case c_res of
                    Left _ -> do
                      (_ :: Maybe ()) <- receiveTimeout 1000 []
                      action nxt_sess nxt_w
                    Right _ -> usend self (Timeout key)
            _ <- spawnLocal $ action s_sess w
            return nxt_jmp
          _ -> return nxt_jmp
      Right a -> return (NormalJump a)

-- | CEP 'Engine' state-machine specification. It's about defining rule or set
--   up options that will change the engine behavior.
type Specification s a = Program (Declare s) a

-- | For compability purpose.
type Definitions s a = Specification s a

-- | Type level trick in order to make sure that the last rule state machine
--   instruction is a 'start' call.
data Started g l = StartingPhase l (Jump (Phase g l))

-- | Holds type information used for later type message deserialization.
data TypeInfo =
    forall a. Serializable a =>
    TypeInfo
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
data PhaseType g l a b where
    PhaseWire  :: CEPWire a b -> PhaseType g l a b
    PhaseMatch :: (a -> g -> l ->  Process (Maybe b)) -> PhaseType g l a b
    PhaseNone  :: PhaseType g l a a
    PhaseSeq   :: Seq -> PhaseStep a b -> PhaseType g l a b

-- | 'Phase' state machine type. Either it's a 'ContCall', it needs a message
--   in order to proceed. If it's a 'DirectCall', it can be started right away
data PhaseCall g l
    = DirectCall (PhaseM g l ())
    | forall a b. (Serializable a, Serializable b) =>
      ContCall (PhaseType g l a b) (b -> PhaseM g l ())

-- | Testifies a 'wants' has been made before interacting with a 'Buffer'
data Token a = Token

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
data RuleInstr g l a where
    Start     :: Jump PhaseHandle -> l -> RuleInstr g l (Started g l)
    NewHandle :: String -> RuleInstr g l (Jump PhaseHandle)
    SetPhase  :: Jump PhaseHandle -> (PhaseCall g l) -> RuleInstr g l ()
    Wants :: Serializable a => Proxy a -> RuleInstr g l (Token a)

type RuleM g l a = Program (RuleInstr g l) a

-- | Defines a phase handle.
phaseHandle :: String -> RuleM g l (Jump PhaseHandle)
phaseHandle n = singleton $ NewHandle n

-- | Indicates we might be interested by a particular message.
wants :: Serializable a => Proxy a -> RuleM g l (Token a)
wants p = singleton $ Wants p

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would be directly
--   executed when triggered.
directly :: Jump PhaseHandle -> PhaseM g l () -> RuleM g l ()
directly h action = singleton $ SetPhase h (DirectCall action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would await for
--   a specific message before starting.
setPhase :: Serializable a
         => Jump PhaseHandle
         -> (a -> PhaseM g l ())
         -> RuleM g l ()
setPhase h action = singleton $ SetPhase h (ContCall PhaseNone action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would await for
--   a specific message before starting. The expected messsage should
--   satisfies the given predicate.
setPhaseIf :: (Serializable a, Serializable b)
           => Jump PhaseHandle
           -> (a -> g -> l -> Process (Maybe b))
           -> (b -> PhaseM g l ())
           -> RuleM g l ()
setPhaseIf h p action = singleton $ SetPhase h (ContCall (PhaseMatch p) action)

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that would require the
--   Netwire state machine to yield a value in order to start.
setPhaseWire :: (Serializable a, Serializable b)
             => Jump PhaseHandle
             -> CEPWire a b
             -> (b -> PhaseM g l ())
             -> RuleM g l ()
setPhaseWire h w action = singleton $ SetPhase h (ContCall (PhaseWire w) action)

-- | Internal use only. Waits for 2 type of messages to come sequentially and
--   apply them to a predicate. If the predicate is statisfied, we yield those
--   value in a tuple, otherwise we switch to the 'Error' state.
__phaseSeq2 :: forall g l a b. (Serializable a, Serializable b)
            => (a -> b -> Bool)
            -> PhaseType g l a (a, b)
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
                -> (a -> b -> PhaseM g l ())
                -> RuleM g l ()
setPhaseSequenceIf h p t =
    singleton $ SetPhase h (ContCall (__phaseSeq2 p) action)
  where
    action (a,b) = t a b

-- | Assigns a 'PhaseHandle' to a 'Phase' state machine that expects 2 types of
--   message to come sequentially.
setPhaseSequence :: (Serializable a, Serializable b)
                 => Jump PhaseHandle
                 -> (a -> b -> PhaseM g l ())
                 -> RuleM g l ()
setPhaseSequence h t =
    setPhaseSequenceIf h (\_ _ -> True) t

-- | Informs CEP engine that rule will start with a particular phase given an
--   initial local state value.
start :: Jump PhaseHandle -> l -> RuleM g l (Started g l)
start h l = singleton $ Start h l

-- | Like 'start' but with a local state set to unit.
start_ :: Jump PhaseHandle -> RuleM g () (Started g ())
start_ h = start h ()

-- | Start a rule with an implicit fork.
startFork :: Jump PhaseHandle -> l -> RuleM g l (Started g l)
startFork rule = startForks [rule]

-- | Start a rule with an implicit fork. Rule may started from
-- different phases.
startForks :: [Jump PhaseHandle] -> l -> RuleM g l (Started g l)
startForks rules state = do
    winit <- initWrapper
    start winit state
  where
    initWrapper = do
      wrapper_init <- phaseHandle "wrapper_init"
      wrapper_clear <- phaseHandle "wrapper_clear"
      wrapper_end <- phaseHandle "wrapper_end"

      directly wrapper_init $ Network.CEP.Types.switch (rules ++ [wrapper_clear])

      directly wrapper_clear $ do
        fork NoBuffer $ Network.CEP.Types.switch (timeout 60 wrapper_clear:rules)
        continue wrapper_end

      directly wrapper_end stop

      return wrapper_init

type PhaseM g l a = ProgramT (PhaseInstr g l) Process a

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
-- 'PhaseLog': Simple log. First parameter is the context and the last
-- one is the log.
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
data PhaseInstr g l a where
    Continue :: Jump PhaseHandle -> PhaseInstr g l a
    Get :: Scope g l a -> PhaseInstr g l a
    Put :: Scope g l a -> a -> PhaseInstr g l ()
    Stop :: PhaseInstr g l a
    Fork :: ForkType -> PhaseM g l () -> PhaseInstr g l ()
    Lift :: Process a -> PhaseInstr g l a
    Suspend :: PhaseInstr g l ()
    Publish :: Serializable e => e -> PhaseInstr g l ()
    PhaseLog :: String -> String -> PhaseInstr g l ()
    Switch :: [Jump PhaseHandle] -> PhaseInstr g l ()
    Peek :: Serializable a => Index -> PhaseInstr g l (Index, a)
    Shift :: Serializable a => Index -> PhaseInstr g l (Index, a)
    Catch :: Exception e => (PhaseM g l a) -> (e -> PhaseM g l a) -> PhaseInstr g l a

-- | Gets scoped state from memory.
get :: Scope g l a -> PhaseM g l a
get s = singleton $ Get s

-- | Gets specific component of scoped state from memory.
gets :: Scope g l a -> (a -> b) -> PhaseM g l b
gets s f = f <$> get s

-- | Updates scoped state in memory.
put :: Scope g l a -> a -> PhaseM g l ()
put s a = singleton $ Put s a

-- | Maps and old scoped state in memory.
modify :: Scope g l a -> (a -> a) -> PhaseM g l ()
modify s k = put s . k =<< get s

-- | Jumps to 'Phase' referenced by given 'PhaseHandle'
continue :: Jump PhaseHandle -> PhaseM g l a
continue p = singleton $ Continue p

-- | Stops the state machine. Depending the current state machine context:
--   - Normal context: State machine stops and is removed from engine, so
--      current invocation of the rule is will not be triggered.
--
--   - Switch context: State machine tries the next alternative 'Phase' without
--     adding back the current state machine to the list of alternatives.
stop :: PhaseM g l a
stop = singleton $ Stop

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
switch :: [Jump PhaseHandle] -> PhaseM g l ()
switch xs = singleton $ Switch xs

-- | Peeks a message from the 'Buffer' given a minimun 'Index'. The 'Buffer' is
--   not altered. If the message is not available, 'Phase' state machine is
--   suspended.
peek :: Serializable a => Token a -> Index -> PhaseM g l (Index, a)
peek _ idx = singleton $ Peek idx

-- | Consumes a message from the 'Buffer' given a minimun 'Index'. The 'Buffer'
--   is altered. If the message is not available, 'Phase' state machine is
--   suspended.
shift :: Serializable a => Token a -> Index -> PhaseM g l (Index, a)
shift _ idx = singleton $ Shift idx

-- | Gathers all the logs produced during 'Phase' state machine run.
data Logs =
    Logs
    { logsRuleName :: !String
      -- ^ Rule name associated with those logs.
    , logsPhaseEntries :: ![(String, String, String)]
      -- ^ Each entry is compound of 'Phase' name, a context and a log value.
    } deriving (Eq, Show, Typeable, Generic)

instance Binary Logs

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
    Logger :: Setting s (Logs -> s -> Process ())
    RuleFinalizer :: Setting s (s -> Process s)
    PhaseBuffer :: Setting s Buffer
    DebugMode :: Setting s Bool
    DefaultHandler :: Setting s (UUID -> StablePrint -> Lazy.ByteString -> s -> Process ())

-- | Definition state machine.
--
-- 'DefineRule': Defines a new rule.
--
-- 'SetSetting: Set a CEP engine setting.
--
-- 'Init': Set a rule to execute before proceeding regular CEP engine
-- execution.
data Declare g a where
    DefineRule :: String -> RuleM g l (Started g l) -> Declare g ()
    SetSetting :: Setting g a -> a -> Declare g ()
    Init :: RuleM g l (Started g l) -> Declare g ()

-- | Defines a new rule.
define :: String -> RuleM g l (Started g l) -> Specification g ()
define name action = singleton $ DefineRule name action

-- | Set a rule to execute before proceeding regular CEP engine execution. That
--   rule must successfully terminate (Doesn't have 'Phase' state machines
--   waiting on the stack).
initRule :: RuleM g l (Started g l) -> Specification g ()
initRule r = singleton $ Init r

-- | Like 'defineSimpleIf' but with a default predicate that lets
--   anything goes throught.
defineSimple :: Serializable a
             => String
             -> (forall l. a -> PhaseM g l ())
             -> Specification g ()
defineSimple n k = defineSimpleIf n (\e _ -> return $ Just e) k

-- | Shorthand to define a simple rule with a single phase. It defines
--   'PhaseHandle' named @phase-1@, calls 'setPhaseIf' with that handle
--   and then call 'start' with a '()' local state initial value.
defineSimpleIf :: (Serializable a, Serializable b)
               => String
               -> (a -> g -> Process (Maybe b))
               -> (forall l. b -> PhaseM g l ())
               -> Specification g ()
defineSimpleIf n p k = define n $ do
    h <- phaseHandle $ n++"-phase"
    setPhaseIf h (\e g _ -> p e g) k
    start h ()

-- | Enables logging by using the given callback. The global state can be read.
setLogger :: (Logs -> s -> Process ()) -> Specification s ()
setLogger k = singleton $ SetSetting Logger k

-- | Sets a rule finalizer. A rule finalizer is called after a rule has been
--   executed. A rule finalizer is able to change CEP engine global state.
setRuleFinalizer :: (s -> Process s) -> Specification s ()
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
setDefaultHandler :: (UUID -> StablePrint -> Lazy.ByteString -> s -> Process ()) -> Specification s ()
setDefaultHandler = singleton . SetSetting DefaultHandler

-- | Request runtime information
data RuntimeInfoRequest = RuntimeInfoRequest ProcessId Bool -- mem?
  deriving (Generic, Typeable)

instance Binary RuntimeInfoRequest
