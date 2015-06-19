{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- Complex Event Processing API
-- It builds a 'Process' out of rules defined by the user. It also support
-- pub/sub feature.
module Network.CEP
    ( module Network.CEP.Types
    , Published(..)
    , Index
    , execute
    , initIndex
    , subscribe
    , occursWithin
    ) where

import           Control.Monad
import           Data.ByteString hiding (foldr, putStrLn, reverse, length, null)
import           Data.Dynamic
import           Data.Foldable (toList, for_, traverse_)
import           Data.Maybe
import qualified Data.Sequence as S
import           Data.Traversable (for)

import           Control.Distributed.Process hiding (call)
import           Control.Distributed.Process.Internal.Types
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import qualified Control.Monad.State as State
import           Control.Monad.Trans
import           Control.Wire (mkPure)
import qualified Data.MultiMap   as MM
import qualified Data.Map.Strict as M
import           Data.Binary
import           Data.Time
import           FRP.Netwire (Session, Timed, clockSession_, dtime)
import           GHC.Generics

import Network.CEP.Buffer
import Network.CEP.Types

-- | That message is sent when a 'Process' asks for a subscription. Used
--   internally.
data Subscribe =
    Subscribe
    { _subType :: !ByteString
      -- ^ Serialized event type.
    , _subPid :: !ProcessId
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
    , pubPid :: !ProcessId
      -- ^ The 'Process' that emitted this publication.
    } deriving (Show, Typeable, Generic)

instance Binary a => Binary (Published a)

-- | CEP engine uses typed subscriptions. Subscribers are referenced by their
--   'ProcessId'. Several subscribers can be associated to a type of message.
type Subscribers = MM.MultiMap Fingerprint ProcessId

-- | Keeps track of time in order to use time varying combinators (FRP).
type TimeSession = Session Process (Timed NominalDiffTime ())

-- | 'Phase' state machine context. Only interesting context is Switch context.
--   When on Switch context, 'Phase' state machine doesn't consume the stack as
--   it would do on normal context. Instead, it will find the first alternatives
--   that successfully produces a result. If no alternative produced a value,
--   the 'Phase' state machine in Switch context is set back to the end of the
--   stack.
data Context g l = NormalContext | SwitchContext [StackSlot g l]

-- | Message emitted by CEP engine 'Match's.
data Msg
    = Appeared [(RuleKey, TypeInfo)] Message
      -- ^ A message has been sent to the CEP engine and a set of rules is
      --   interested.
    | SubRequest Subscribe
      -- ^ CEP engine receives a subscription request.
    | Discarded
      -- ^ A message has been sent to the CEP engine but no rule is interested
      --   in.

-- | CEP engine current step.
data MachineStep
    = InitStep
      -- ^ The engine has just started. It runs init rule (if any) then switch
      --   'NormalStep'.
    | NormalStep
      -- ^ Regular CEP execution step.

-- | Holds init rule state.
data InitRule s =
    InitRule
    { _initRuleData :: !(RuleData s)
      -- ^ Init rule state.
    , _initRuleTypes :: !(M.Map Fingerprint TypeInfo)
      -- ^ Keep track of type of messages handled by the init rule.
    }

-- | Main CEP engine data structure.
data Machine s =
    Machine
    { _machRuleData :: !(M.Map RuleKey (RuleData s))
      -- ^ Rules defined by the users.
    , _machSession :: !TimeSession
      -- ^ Time tracking session.
    , _machSubs :: !Subscribers
      -- ^ Subscribers interested by event issued by this CEP engine.
    , _machLogger :: !(Maybe (Logs -> s -> Process ()))
      -- ^ Logger callback.
    , _machRuleFin :: !(Maybe (s -> Process s))
      -- ^ Callback used when a rule's completed.
    , _machRuleCount :: !Int
      -- ^ It will get you the number of rules that CEP engine handles. but
      --   it's use to order rule by order in appearence when generating
      --   'RuleKey'.
    , _machPhaseBuf :: !Buffer
      -- ^ Default buffer when forking a new 'Phase' state machine.
    , _machTypeMap :: !(MM.MultiMap Fingerprint (RuleKey, TypeInfo))
      -- ^ Keep track of every rule interested by a certain type. It also keep
      --   type information that helps us deserializing.
    , _machState :: !s
      -- ^ CEP engine global state.
    , _machDebugMode :: !Bool
      -- ^ Set the CEP engine in debug mode, dumping more internal log to
      --   the terminal.
    , _machInitRule :: !(Maybe (InitRule s))
      -- ^ Rule to run at 'InitStep' step.
    , _machOnReady :: !(Process ())
      -- ^ Action run when the CEP engine has been initialized.
    }

_printDebugStr :: MonadIO m => Machine g -> String -> m ()
_printDebugStr Machine{..} s =
    when _machDebugMode $
      liftIO $ putStrLn s

_printDebug :: (Show a, MonadIO m) => Machine g -> a -> m ()
_printDebug Machine{..} a =
    when _machDebugMode $
      liftIO $ print a

_whenDebugging :: Monad m => PhaseState g l -> m () -> m ()
_whenDebugging PhaseState{..} action =
    when _phaseDebugMode action

-- | Creates CEP engine state with default properties.
emptyMachine :: s -> Machine s
emptyMachine s =
    Machine
    { _machRuleData  = M.empty
    , _machSession   = clockSession_
    , _machSubs      = MM.empty
    , _machLogger    = Nothing
    , _machRuleFin   = Nothing
    , _machRuleCount = 0
    , _machPhaseBuf  = fifoBuffer Unbounded
    , _machTypeMap   = MM.empty
    , _machState     = s
    , _machDebugMode = False
    , _machInitRule  = Nothing
    , _machOnReady   = return ()
    }

-- | Fills type tracking map with every type of messages needed by the engine
--   rules.
fillMachineTypeMap :: Machine s -> Machine s
fillMachineTypeMap st@Machine{..} =
    st { _machTypeMap = M.foldrWithKey go MM.empty _machRuleData }
  where
    go key (RuleData _ _ _ _ _ typs) m =
        let insertF i@(TypeInfo fprt _) = MM.insert fprt (key, i) in
        foldr insertF m typs

-- | Fills a type tracking map with every type of messages needed by the init
--   rule.
initRuleTypeMap :: RuleData s -> M.Map Fingerprint TypeInfo
initRuleTypeMap (RuleData _ _ _ _ _ typs) = foldr go M.empty typs
  where
    go i@(TypeInfo fprt _) = M.insert fprt i

-- | Constructs a CEP engine state by using an initial global state value and a
--   definition state machine.
buildMachine :: s -> Definitions s () -> Machine s
buildMachine s defs = go (emptyMachine s) $ view defs
  where
    go :: Machine s -> ProgramView (Declare s) () -> Machine s
    go st (Return _) = fillMachineTypeMap st
    go st (DefineRule n m :>>= k) =
        let idx = _machRuleCount st
            key = RuleKey idx n
            dat = buildRuleData n m
            mp  = M.insert key dat $ _machRuleData st
            st' = st { _machRuleData  = mp
                     , _machRuleCount = idx + 1
                     } in
        go st' $ view $ k ()
    go st (Init m :>>= k) =
        let dat  = buildRuleData "init" m
            typs = initRuleTypeMap dat
            ir   = InitRule dat typs
            st'  = st { _machInitRule = Just ir } in
        go st' $ view $ k ()
    go st (SetSetting Logger  action :>>= k) =
        let st' = st { _machLogger = Just action } in
        go st' $ view $ k ()
    go st (SetSetting RuleFinalizer action :>>= k) =
        let st' = st { _machRuleFin = Just action } in
        go st' $ view $ k ()
    go st (SetSetting PhaseBuffer buf :>>= k ) =
        let st' = st { _machPhaseBuf = buf } in
        go st' $ view $ k ()
    go st (SetSetting DebugMode b :>>= k) =
        let st' = st { _machDebugMode = b } in
        go st' $ view $ k ()
    go st (SetSetting OnReady action :>>= k) =
        let st' = st { _machOnReady = action } in
        go st' $ view $ k ()

-- | Simple 'Match' that expects a subscription request.
subMatch :: Match Msg
subMatch = match $ \sub -> return $ SubRequest sub

-- | Constructs a 'Match' that will only keep messages that rules are
--   interested in. Other kind of messager are just discarded.
buildMatch :: Machine g -> Match Msg
buildMatch Machine{..} =
    matchAny $ \msg ->
      case MM.lookup (messageFingerprint msg) _machTypeMap of
        []  -> return Discarded
        xs  -> return $ Appeared xs msg

initRuleMatch :: M.Map Fingerprint TypeInfo -> Match (Maybe (Message, TypeInfo))
initRuleMatch m =
    matchAny $ \msg ->
      case M.lookup (messageFingerprint msg) m of
        Nothing  -> return Nothing
        Just typ -> return $ Just (msg, typ)

-- | Main CEP engine loop
--   ====================
--
--   InitStep
--   --------
--   If the user register a init rule. We try to run it by passing 'NoMessage'
--   to the rule state machine. It allows to define a init rule that maybe
--   doesn't need a message to start or will carrying some action before asking
--   for a particular message.
--   If the rule state machine returns an empty stack, it means the init rule
--   has been executed successfully. Otherwise it means it needs more inputs.
--   In this case we're feeding the init rule with incoming messages until
--   the rule state machine returns an empty stack.
--
--   NormalStep
--   ----------
--   Waits for a message to come.
--     1. 'Discarded': It starts a new loop.
--     2. 'SubRequest': It registers the new subscribers to subscribers map.
--     3. 'Appeared': It dispatches the message to the according rule state
--        machine.
runMachine :: MachineStep -> Machine s -> Process ()
runMachine InitStep st =
    case _machInitRule st of
      Nothing -> do
        _machOnReady st
        runMachine NormalStep st
      Just (InitRule rd typs) -> do
        (rd', g') <- runRule st NoMessage rd
        let st' = st { _machState = g' }
            matches = [initRuleMatch typs]
            loop tmpRd tmpSt = do
              res <- receiveWait matches
              case res of
                Nothing          -> loop tmpRd tmpSt
                Just (msg, info) -> do
                  (newRd, newG) <- runRule tmpSt (GotMessage info msg) tmpRd
                  let newSt = tmpSt { _machState = newG }
                  if nullStack newRd
                      then do
                      _machOnReady newSt
                      runMachine NormalStep newSt
                      else loop newRd newSt
        if nullStack rd'
            then do
            _machOnReady st'
            runMachine NormalStep st'
            else loop rd' st'
runMachine step@NormalStep st = do
    msg <- receiveWait matches
    case msg of
      Discarded -> runMachine step st
      SubRequest sub ->
         let key   = decodeFingerprint $ _subType sub
             value = _subPid sub
             subs' = MM.insert key value $ _machSubs st
             st'   = st { _machSubs = subs' } in
        runMachine step st'
      Appeared tups imsg -> do
        let action =
              for_ tups $ \(key, info) -> do
                st' <- State.get
                let dts = _machRuleData st'
                case M.lookup key dts of
                  Just rd -> do
                      (rd', g') <- lift $ runRule st' (GotMessage info imsg) rd
                      let  st'' = st' { _machRuleData = M.insert key rd' dts
                                      , _machState    = g'
                                      }
                      State.put st''
                  _ -> fail "runMachine: ruleKey is invalid (impossible)"
        st' <- State.execStateT action st
        runMachine step st'
  where
    matches = [subMatch, buildMatch st]

-- | Executes a CEP definitions to the 'Process' monad given a initial global
--   state.
execute :: s -> Definitions s () -> Process ()
execute s defs = runMachine InitStep machine
  where
    machine = buildMachine s defs

-- | 'Phase' state machine environment and state data structure.
data PhaseState g l =
    PhaseState
    { _phaseState :: !g
      -- ^ Copy of the global state.
    , _phaseMap :: !(M.Map String (Phase g l))
      -- ^ All rule 'Phase's.
    , _phaseSubs :: !Subscribers
      -- ^ All the subscribers of the CEP engine.
    , _phaseStack :: ![StackSlot g l]
      -- ^ Stack of active 'Phase' state machine.
    , _phaseHandled :: ![StackSlot g l]
      -- ^ List of parked 'Phase' state machine. That field is only used on per
      --   rule run basis. It's a temporary storage for parked 'Phase's that
      --   arise during 'Phase' state machine execution. Once the rule state
      --   machine has finished, that list becomes the next stack value and
      --   then sent to an empty list.
    , _phaseLogs    :: !(Maybe (S.Seq (String, String, String)))
      -- ^ Sequence that gathers all the log of a 'Phase' state machine
      --   execution if logging is enabled.
    , _phaseSession :: !TimeSession
      -- ^ Time tracking session.
    , _phaseBaseBuf :: !Buffer
      -- ^ Initial buffer when forking a new 'Phase' and it asks for an empty
      -- one.
    , _phaseDebugMode :: !Bool
    }

-- | Stack element.
data StackSlot g l =
    StackSlot
    { _slotBuffer :: !Buffer
      -- ^ Buffer associated to that 'Phase'.
    , _slotPhase :: !(Phase g l)
      -- ^ 'Phase' state machine.
    , _slotState :: !l
      -- ^ 'Phase' local state copy.
    , _slotCtx :: !(Context g l)
      -- ^ Current 'Phase' context.
    }

-- | Holds type information used for later type message desarialization.
data TypeInfo =
    forall a. Serializable a =>
    TypeInfo
    { _typFingerprint :: !Fingerprint
    , _typeProxy      :: !(Proxy a)
    }

-- | Rule state data structure.
data RuleData g =
    forall l.
    RuleData
    { _ruleStartPhase :: !(Phase g l)
      -- ^ The 'Phase' referenced by the 'start' when the rule has been
      --   defined.
    , _ruleStartState :: !l
      -- ^ Initial local state of the rule.
    , _rulePhases :: !(M.Map String (Phase g l))
      -- ^ All the 'Phase's of the rule.
    , _ruleDataName :: !String
      -- ^ Rule name.
    , _ruleStack :: ![StackSlot g l]
      -- ^ Rule stack of execution.
    , _ruleTypes :: ![TypeInfo]
      -- ^ All the 'TypeInfo' gathered while running rule state machine. It's
      --   only used at the CEP engine initialization phase, when calling
      --   'buildMachine'.
    }

nullStack :: RuleData g -> Bool
nullStack (RuleData _ _ _ _ stk _) = null stk

-- | Used as a key for referencing a rule at upmost level of the CEP engine.
--   The point is to allow the user to refer to rules by their name while
--   being able to know which rule has been defined the first. That give us
--   prioritization.
data RuleKey =
    RuleKey
    { _ruleKeyId   :: !Int
    , _ruleKeyName :: !String
    } deriving Show

instance Eq RuleKey where
    RuleKey k1 _ == RuleKey k2 _ = k1 == k2

instance Ord RuleKey where
    compare (RuleKey k1 _) (RuleKey k2 _) = compare k1 k2

-- | Response given by the 'Phase' state machine execution.
data Output g l
    = Done (PhaseState g l) [StackSlot g l]
      -- ^ Ends successfully. Produced a new 'PhaseState' and have stack slots
      --   to append them at the end of stack.
    | Suspended
      -- ^ 'Phase' state machine decided to be parked.
    | Stopped
      -- ^ 'Phase' state machine decided.

data RuleInput
    = NoMessage
    | GotMessage TypeInfo Message
      -- ^ When we've received a message from the 'Process' mailbox.

-- | Rule execution main loop. Its goal is to deserialize the message we got
--   from the 'Process' mailbox then feed the stack of 'Phase' with it. It
--   starts to run the stack of 'Phase' and awaiting of the result. After that
--   it update the rule state accordingly.
runRule :: Machine g
        -> RuleInput
        -> RuleData g
        -> Process (RuleData g, g)
runRule mach input (RuleData sp st ps dn stk tps) = do
    jobs <- case input of
      GotMessage (TypeInfo _ (_ :: Proxy a)) msg -> do
        Just (a :: a) <- unwrapMessage msg
        case stk of
          _:_ ->
            let mapF xstk =
                    let buf'  = bufferInsert a $ _slotBuffer xstk
                        xstk' = xstk { _slotBuffer = buf' } in
                    xstk' in
            return $ fmap mapF stk
          _ -> let buf = bufferInsert a $ _machPhaseBuf mach in
               return [StackSlot buf sp st NormalContext]
      NoMessage ->
        case stk of
          [] -> return [StackSlot (_machPhaseBuf mach) sp st NormalContext]
          _  -> return stk
    let job:rest = jobs
        pstate = PhaseState
                 { _phaseState   = _machState mach
                 , _phaseMap     = ps
                 , _phaseSubs    = _machSubs mach
                 , _phaseLogs    = fmap (const S.empty) $_machLogger mach
                 , _phaseSession = _machSession mach
                 , _phaseStack   = rest
                 , _phaseHandled = []
                 , _phaseBaseBuf = _machPhaseBuf mach
                 , _phaseDebugMode = _machDebugMode mach
                 }
    pstate' <- runPhase pstate job
    g_may   <- for (_machRuleFin mach) $ \k -> k $ _phaseState pstate'
    let g' = fromMaybe (_phaseState pstate') g_may
        rd = RuleData
             { _ruleStartPhase = sp
             , _ruleStartState = st
             , _rulePhases     = ps
             , _ruleDataName   = dn
             , _ruleStack      = _phaseHandled pstate'
             , _ruleTypes      = tps
             }
        logAction = do
          k     <- _machLogger mach
          plogs <- _phaseLogs pstate'
          if not $ S.null plogs
              then
                let lgs = Logs
                          { logsRuleName     = dn
                          , logsPhaseEntries = toList plogs
                          }
                in return $ k lgs g'
              else Nothing

    traverse_ id logAction
    return (rd, g')

-- | Builds a list of 'TypeInfo' out types needed by 'PhaseStep' data
--   contructor.
buildSeqList :: Seq -> [TypeInfo]
buildSeqList Nil = []
buildSeqList (Cons (prx :: Proxy a) rest) =
    TypeInfo (fingerprint (undefined :: a)) prx : buildSeqList rest

--  | Builds a list of 'TypeInfo' out types need by 'Phase's.
buildTypeList :: Foldable f => f (Phase g l) -> [TypeInfo]
buildTypeList = foldr go []
  where
    go (Phase _ call) is =
        case call of
          ContCall (typ :: PhaseType g l a b) _ ->
            case typ of
              PhaseSeq sq _ -> buildSeqList sq ++ is
              _ ->
                let i = TypeInfo (fingerprint (undefined :: a)) (Proxy :: Proxy a)
                in i : is
          _ -> is

-- | Executes a rule state machine in order to produce a rule state data
--   structure.
buildRuleData :: String -> RuleM g l (Started g l) -> RuleData g
buildRuleData name rls = go M.empty [] $ view rls
  where
    go ps tpes (Return (StartingPhase l p)) =
        RuleData
        { _ruleStartPhase  = p
        , _ruleStartState  = l
        , _rulePhases      = ps
        , _ruleDataName    = name
        , _ruleStack       = []
        , _ruleTypes       = tpes ++ buildTypeList ps
        }
    go ps tpes (Start ph l :>>= k) =
        case M.lookup (_phHandle ph) ps of
          Just p  -> go ps tpes $ view $ k (StartingPhase l p)
          Nothing -> error "phase not found (Start)"
    go ps tpes (NewHandle n :>>= k) =
        let p      = Phase n (DirectCall $ return ())
            handle = PhaseHandle n
            ps'    = M.insert n p ps in
        go ps' tpes $ view $ k handle
    go ps tpes (SetPhase ph call :>>= k) =
        case M.lookup (_phHandle ph) ps of
          Just p ->
            let p'  = p { _phCall = call }
                ps' = M.insert (_phName p) p' ps in
            go ps' tpes $ view $ k ()
          Nothing -> error "phase not found (UpdatePhase)"
    go ps tpes (Wants (prx :: Proxy a) :>>= k) =
        let tok = Token :: Token a
            tpe = TypeInfo (fingerprint (undefined :: a)) prx in
        go ps (tpe:tpes) $ view $ k tok

noop :: PhaseM g l ()
noop = return ()

-- | Simple product type used as a result of message buffer extraction.
data Extraction b =
    Extraction
    { _extractBuf :: !Buffer
      -- ^ The buffer we have minus the elements we extracted from it.
    , _extractMsg :: !b
      -- ^ The extracted message.
    }

-- | Extracts messages from a 'Buffer' based based on 'PhaseType' need.
extractMsg :: (Serializable a, Serializable b)
           => PhaseType g l a b
           -> g
           -> l
           -> Buffer
           -> Process (Maybe (Extraction b))
extractMsg typ g l buf =
    case typ of
      PhaseWire _  -> error "phaseWire: not implemented yet"
      PhaseMatch p -> extractMatchMsg p g l buf
      PhaseNone    -> extractNormalMsg (Proxy :: Proxy a) buf
      PhaseSeq _ s -> extractSeqMsg s buf

-- -- | Extracts messages from a Netwire wire.
-- extractWireMsg :: forall a b. (Serializable a, Serializable b)
--                => TimeSession
--                -> CEPWire a b
--                -> Buffer
--                -> Process (Maybe (Extraction b))
-- extractWireMsg = error "wire extraction: not implemented yet"

-- | Extracts a message that satifies the predicate. If it does, it's passed
--   to an effectful callback.
extractMatchMsg :: Serializable a
                => (a -> g -> l -> Process (Maybe b))
                -> g
                -> l
                -> Buffer
                -> Process (Maybe (Extraction b))
extractMatchMsg p g l buf = go (-1)
  where
    go lastIdx =
        case bufferGetWithIndex lastIdx buf of
          (Just (newIdx, a), newBuf) -> do
            res <- p a g l
            case res of
              Nothing -> go newIdx
              Just b  ->
                let ext = Extraction
                          { _extractBuf = newBuf
                          , _extractMsg = b
                          } in
                return $ Just ext
          _ -> return Nothing

-- | Extracts a simple message from the 'Buffer'.
extractNormalMsg :: forall a. Serializable a
                 => Proxy a
                 -> Buffer
                 -> Process (Maybe (Extraction a))
extractNormalMsg _ buf =
    case bufferGet buf of
      (Just a, buf') ->
        let ext = Extraction
                  { _extractBuf = buf'
                  , _extractMsg = a
                  } in
        return $ Just ext
      _ -> return Nothing

-- | Extracts a message based on messages coming sequentially.
extractSeqMsg :: PhaseStep a b -> Buffer -> Process (Maybe (Extraction b))
extractSeqMsg s sbuf = go (-1) sbuf s
  where
    go lastIdx buf (Await k) =
        case bufferGetWithIndex lastIdx buf of
          (Just (idx, i), buf') -> go idx buf' $ k i
          _                     -> return Nothing
    go _ buf (Emit b) =
        let ext = Extraction
                  { _extractBuf = buf
                  , _extractMsg = b
                  } in
        return $ Just ext
    go _ _ _ = return Nothing

-- | Notifies every subscriber that a message those are interested in has
--   arrived.
notifySubscribers :: Serializable a => PhaseState g l -> a -> Process ()
notifySubscribers PhaseState{..} a = do
    self <- getSelfPid
    for_ subs $ \pid ->
      usend pid (Published a self)
  where
    subs = MM.lookup (fingerprint $ asSub a) _phaseSubs

-- | Execute a 'Phase' state machine. If it's 'DirectCall' 'Phase', it's runned
--   directly. If it's 'ContCall' one, we make sure we can satisfy its
--   dependency. Otherwise, we 'Suspend' that phase.
runPhaseCall :: PhaseState g l
             -> Buffer
             -> l
             -> Phase g l
             -> Process (Output g l)
runPhaseCall sst buf l p =
    case _phCall p of
      DirectCall action -> runSM (_phName p) sst buf l [] action
      ContCall typ k -> do
        res <- extractMsg typ (_phaseState sst) l buf
        case res of
          Just (Extraction buf' b) -> do
            notifySubscribers sst b
            runSM (_phName p) sst buf' l [] (k b)
          Nothing                  -> return Suspended

-- | 'Phase' state machine execution main loop. Runs until its stack is empty
--   except if get a 'Suspend' or 'Stop' instruction.
runSM :: String
      -> PhaseState g l
      -> Buffer
      -> l
      -> [StackSlot g l]
      -> PhaseM g l ()
      -> Process (Output g l)
runSM pname st buf l stk action = viewT action >>= go
  where
    go (Return _) = return $ Done st $ reverse stk
    go (Continue ph :>>= _) =
        case M.lookup (_phHandle ph) $ _phaseMap st of
          Just np -> do
            let slot = StackSlot buf np l NormalContext
            runSM pname st buf l (slot:stk) noop
          Nothing -> fail "phase not found (Continue)"
    go (Save s :>>= k) =
        let st' = st { _phaseState = s } in
        runSM pname st' buf l stk $ k ()
    go (Load :>>= k) =
        let s = _phaseState st in
        runSM pname st buf l stk $ k s
    go (Get Global :>>= k) =
        let s = _phaseState st in
        runSM pname st buf l stk $ k s
    go (Get Local :>>= k) =
        runSM pname st buf l stk $ k l
    go (Put Global s :>>= k) =
        let st' = st { _phaseState = s } in
        runSM pname st' buf l stk $ k ()
    go (Put Local l' :>>= k) =
        runSM pname st buf l' stk $ k ()
    go (Stop :>>= _) = return Stopped
    go (Fork typ naction :>>= k) =
        let newBuf = case typ of
                       NoBuffer   -> _phaseBaseBuf st
                       CopyBuffer -> buf
            newP = Phase pname (DirectCall naction)
            slot = StackSlot newBuf newP l NormalContext in
        runSM pname st buf l (slot:stk) $ k ()
    go (Lift m :>>= k) = do
        a <- m
        runSM pname st buf l stk $ k a
    go (Suspend :>>= _) = return Suspended
    go (Publish e :>>= k) = do
        let key = fingerprint $ asSub e
        self <- getSelfPid
        for_ (MM.lookup key $ _phaseSubs st) $ \pid ->
          usend pid (Published e self)
        runSM pname st buf l stk $ k ()
    go (PhaseLog ctx lg :>>= k) =
        let logs = fmap (S.|> (pname,ctx,lg)) $ _phaseLogs st
            st'  = st { _phaseLogs = logs } in
        runSM pname st' buf l stk $ k ()
    go (Switch xs :>>= _) = do
        let collectF ph =
              let res = M.lookup (_phHandle ph) $ _phaseMap st
                  fin = fmap (\pp -> StackSlot buf pp l NormalContext) res in
              fin
            slotsM = sequence $ fmap collectF xs
        case slotsM of
          Just slots ->
            let p      = Phase pname (DirectCall $ return ())
                parent = StackSlot buf p l (SwitchContext slots) in
            return $ Done st $ reverse (parent:stk)
          _ -> fail "impossible runPhase: one handle is invalid"
    go (Peek idx :>>= k) = do
        case bufferPeek idx buf of
          Nothing -> runSM pname st buf l stk suspend
          Just r  -> runSM pname st buf l stk $ k r
    go (Shift idx :>>= k) =
        case bufferGetWithIndex idx buf of
          (Nothing, _)   -> runSM pname st buf l stk suspend
          (Just r, buf') -> runSM pname st buf' l stk $ k r

-- | Execute a 'StackSlot' and update the 'Phase' execution state based of the
--   current 'Phase' context and result evaluation.
runPhase :: PhaseState g l -> StackSlot g l -> Process (PhaseState g l)
runPhase st@PhaseState{..} slot@(StackSlot sbuf p sl ctx) =
    case ctx of
      NormalContext -> do
        res <- runPhaseCall st sbuf sl p
        case res of
          Suspended ->
            case _phaseStack of
              x:xs ->
                let st' = st { _phaseHandled = slot : _phaseHandled
                             , _phaseStack   = xs
                             } in
                runPhase st' x
              _ ->
                let st' = st { _phaseHandled = reverse (slot : _phaseHandled) }
                in return st'
          Stopped ->
            case _phaseStack of
              x:xs ->
                let st' = st { _phaseStack = xs } in
                runPhase st' x
              _ ->
                let st' = st { _phaseHandled = reverse _phaseHandled } in
                return st'
          Done st' slots ->
            case _phaseStack ++ slots of
              x:xs ->
                let st'' = st' { _phaseStack = xs } in
                runPhase st'' x
              _ -> return st'
      SwitchContext alts ->
        let loop done [] =
              let slot' = slot { _slotCtx = SwitchContext $ reverse done } in
              case _phaseStack of
                x:xs ->
                  let st' = st { _phaseHandled = slot' : _phaseHandled
                               , _phaseStack   = xs
                               } in
                  runPhase st' x
                _ ->
                  let st' = st { _phaseHandled = reverse (slot':_phaseHandled) }
                  in return st'
            loop done (a:as) = do
              res <- runPhaseCall st sbuf sl $ _slotPhase a
              case res of
                Suspended      -> loop (a:done) as
                Stopped        -> loop done as
                Done st' slots ->
                  case _phaseStack ++ slots of
                    x:xs ->
                      let st'' = st' { _phaseStack = xs } in
                      runPhase st'' x
                    _ -> return st' in
        loop [] alts

-- | Subscribes for a specific type of event. Every time that event occures,
--   this 'Process' will receive a 'Published a' message.
subscribe :: Serializable a => ProcessId -> Sub a -> Process ()
subscribe pid sub = do
    self <- getSelfPid
    let key  = fingerprint sub
        fgBs = encodeFingerprint key
    usend pid (Subscribe fgBs self)

-- | @occursWithin n t@ Lets through an event every time it occurs @n@ times
--   within @t@ seconds.
occursWithin :: Int -> NominalDiffTime -> CEPWire a a
occursWithin cnt frame = go 0 frame
  where
    go nb t = mkPure $ \ds a ->
        let nb' = nb + 1
            t'  = t - dtime ds in
        if nb' == cnt && t' > 0
        then (Right a, go 0 frame)
        else (Left (), go nb' t')
