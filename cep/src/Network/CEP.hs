{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE Rank2Types          #-}
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
    , Engine
    , ExecutionInfo(..)
    , ExecutionReport(..)
    , Published(..)
    , Index
    , RuleName(..)
    , RunResult(..)
    , RunInfo(..)
    , RuleInfo(..)
    , Subscribe(..)
    , Tick(..)
    , Some(..)
    , cepEngine
    , feedEngine
    , execute
    , stackPhaseInfoPhaseName
    , newSubscribeRequest
    , initIndex
    , incoming
    , subscribeRequest
    , subscribe
    , stepForward
    , runItForever
    , occursWithin
    ) where

import           Control.Monad
import           Data.ByteString (ByteString)
import           Data.Dynamic
import           Data.Foldable (for_)
import           Data.Maybe (fromMaybe)
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
import qualified Data.Set        as Set
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
    { _subType :: ! ByteString
      -- ^ Serialized event type.
    , _subPid :: !ProcessId
      -- ^ Subscriber 'ProcessId'
    } deriving (Show, Typeable, Generic)

instance Binary Subscribe

newSubscribeRequest :: forall proxy a. Serializable a
                    => ProcessId
                    -> proxy a
                    -> Subscribe
newSubscribeRequest pid _ = Subscribe bytes pid
  where
    bytes = encodeFingerprint $ fingerprint (undefined :: a)

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

type SMLogs = S.Seq (String, String, String)

-- | Keeps track of time in order to use time varying combinators (FRP).
type TimeSession = Session Process (Timed NominalDiffTime ())

data Input
    = NoMessage
    | GotMessage TypeInfo Message

--------------------------------------------------------------------------------
-- Public execution information.
--------------------------------------------------------------------------------
data RuleName = InitRuleName | RuleName String deriving Show

data RuleInfo =
    RuleInfo
    { ruleInfoName   :: !RuleName
    , ruleInfoReport :: !ExecutionReport
    } deriving Show

data RunResult
    = SubscriptionReceived
    | RulesBeenTriggered [RuleInfo]
    | MsgIgnored
    | Noop
    deriving Show

data RunInfo =
    RunInfo
    { runTotalProcessedMsgs :: !Int
    , runResult             :: !RunResult
    } deriving Show

emptyRunInfo :: RunInfo
emptyRunInfo =
    RunInfo
    { runTotalProcessedMsgs = 0
    , runResult             = Noop
    }

data Tick a where
    Tick       :: Tick RunInfo
    Incoming   :: Message -> Tick RunInfo
    NewSub     :: Subscribe -> Tick ()
    GetSetting :: EngineSetting a -> Tick a

data EngineSetting a where
    EngineDebugMode :: EngineSetting Bool

--------------------------------------------------------------------------------
-- CEP Engine finit state machine represented as a Mealy machine.
newtype Engine = Engine { unEngine :: forall a. Tick a -> Process (a, Engine) }

stepForward :: Tick a -> Engine -> Process (a, Engine)
stepForward i (Engine k) = k i

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
    , _machTotalProcMsgs :: !Int
    }

_printDebugStr :: MonadIO m => Machine g -> String -> m ()
_printDebugStr Machine{..} s =
    when _machDebugMode $
      liftIO $ putStrLn s

_printDebug :: (Show a, MonadIO m) => Machine g -> a -> m ()
_printDebug Machine{..} a =
    when _machDebugMode $
      liftIO $ print a

-- | Creates CEP engine state with default properties.
emptyMachine :: s -> Machine s
emptyMachine s =
    Machine
    { _machRuleData      = M.empty
    , _machSession       = clockSession_
    , _machSubs          = MM.empty
    , _machLogger        = Nothing
    , _machRuleFin       = Nothing
    , _machRuleCount     = 0
    , _machPhaseBuf      = fifoBuffer Unbounded
    , _machTypeMap       = MM.empty
    , _machState         = s
    , _machDebugMode     = False
    , _machInitRule      = Nothing
    , _machOnReady       = return ()
    , _machTotalProcMsgs = 0
    }

-- | Fills type tracking map with every type of messages needed by the engine
--   rules.
fillMachineTypeMap :: Machine s -> Machine s
fillMachineTypeMap st@Machine{..} =
    st { _machTypeMap = M.foldrWithKey go MM.empty _machRuleData }
  where
    go key rd m =
        let insertF i@(TypeInfo fprt _) = MM.insert fprt (key, i) in
        foldr insertF m $ _ruleTypes rd

-- | Fills a type tracking map with every type of messages needed by the init
--   rule.
initRuleTypeMap :: RuleData s -> M.Map Fingerprint TypeInfo
initRuleTypeMap rd = foldr go M.empty $ _ruleTypes rd
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
        let logs = fmap (const S.empty) $ _machLogger st
            idx = _machRuleCount st
            key = RuleKey idx n
            dat = buildRuleData n m (_machPhaseBuf st) logs
            mp  = M.insert key dat $ _machRuleData st
            st' = st { _machRuleData  = mp
                     , _machRuleCount = idx + 1
                     } in
        go st' $ view $ k ()
    go st (Init m :>>= k) =
        let logs = fmap (const S.empty) $ _machLogger st
            dat  = buildRuleData "init" m (_machPhaseBuf st) logs
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

-- | Main CEP state-machine
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
cepEngine :: s -> Definitions s () -> Engine
cepEngine s defs = Engine $ cepInit st
  where
    st = buildMachine s defs

cepInit :: Machine s -> Tick a -> Process (a, Engine)
cepInit st i =
    case _machInitRule st of
      Nothing -> do
          _machOnReady st
          cepCruise st i
      Just ir -> cepInitRule ir st i

cepSubRequest :: Machine g -> Subscribe -> Machine g
cepSubRequest st@Machine{..} (Subscribe tpe pid) = nxt_st
  where
    key      = decodeFingerprint tpe
    nxt_subs = MM.insert key pid _machSubs
    nxt_st   = st { _machSubs = nxt_subs }

defaultHandler :: Machine g
               -> (forall b. Machine g -> Tick b -> Process (b, Engine))
               -> Tick a
               -> Process (a, Engine)
defaultHandler st next (NewSub sub) =
    return ((), Engine $ next $ cepSubRequest st sub)
defaultHandler st next Tick =
    return (RunInfo (_machTotalProcMsgs st) MsgIgnored, Engine $ next st)
defaultHandler st next (Incoming _) =
    return (RunInfo (_machTotalProcMsgs st) MsgIgnored, Engine $ next st)
defaultHandler st next (GetSetting s) =
    case s of
      EngineDebugMode -> return (_machDebugMode st, Engine $ next st)

interestingMsg :: (Fingerprint -> Bool) -> Message -> Bool
interestingMsg k msg = k $ messageFingerprint msg

cepInitRule :: InitRule g -> Machine g -> Tick a -> Process (a, Engine)
cepInitRule ir@(InitRule rd typs) st@Machine{..} i =
    case i of
      Tick -> go NoMessage _machTotalProcMsgs
      Incoming m
        | interestingMsg (\frp -> M.member frp typs) m ->
          let tpe       = typs M.! messageFingerprint m
              msg       = GotMessage tpe m
              msg_count = _machTotalProcMsgs + 1 in
          go msg msg_count
        | otherwise -> defaultHandler st (cepInitRule ir) i
      _ -> defaultHandler st (cepInitRule ir) i
  where
    go msg msg_count = do
      let (StackSM k) = _ruleStack rd
          input       = StackIn _machSubs _machState msg
      (StackOut g infos res, nxt_stk) <- k input
      let new_rd = rd { _ruleStack = nxt_stk }
          nxt_st = st { _machState         = g
                      , _machTotalProcMsgs = msg_count
                      }
          rinfo = RuleInfo InitRuleName infos
          info  = RunInfo msg_count (RulesBeenTriggered [rinfo])
      case res of
        EmptyStack -> do
          _machOnReady
          return (info, Engine $ cepCruise nxt_st)
        _ -> return (info, Engine $ cepInitRule (InitRule new_rd typs) nxt_st)

cepCruise :: Machine s -> Tick a -> Process (a, Engine)
cepCruise st tick =
    case tick of
      Tick ->
        let _F (k,r) = (k, r, NoMessage)
            tups     = fmap _F $ M.assocs $ _machRuleData st in
        go tups (_machTotalProcMsgs st)
      Incoming m | interestingMsg (MM.member (_machTypeMap st)) m -> do
        let fpt = messageFingerprint m
        tups <- for (MM.lookup fpt $ _machTypeMap st) $ \(key, info) ->
          case M.lookup key $ _machRuleData st of
            Just rd -> return (key, rd, GotMessage info m)
            _       -> fail "ruleKey is invalid (impossible)"
        go tups (_machTotalProcMsgs st + 1)
      _ -> defaultHandler st cepCruise tick
  where
    go tups msg_count = do
      let action = for tups $ \(key, rd, i) -> do
            tmp_st          <- State.get
            (rinfo, nxt_st) <- lift $ broadcastInput tmp_st key rd i
            State.put nxt_st
            return rinfo

      (infos, tmp_st) <- State.runStateT action st
      let nxt_st = tmp_st { _machTotalProcMsgs = msg_count }
          rinfo  = RunInfo msg_count (RulesBeenTriggered infos)
      return (rinfo, Engine $ cepCruise nxt_st)

broadcastInput st key rd i = do
    let input     = StackIn (_machSubs st) (_machState st) i
        StackSM k = _ruleStack rd
    (StackOut g infos _, nxt_stk) <- k input
    let nxt_rd  = rd { _ruleStack = nxt_stk }
        nxt_dts = M.insert key nxt_rd $ _machRuleData st
        nxt_st  = st { _machRuleData = nxt_dts
                     , _machState    = g
                     }
        info = RuleInfo (RuleName $ _ruleDataName nxt_rd) infos
    return (info, nxt_st)

-- | Executes a CEP definitions to the 'Process' monad given a initial global
--   state.
execute :: s -> Definitions s () -> Process ()
execute s defs = runItForever $ cepEngine s defs

runItForever :: Engine -> Process ()
runItForever start_eng = do
  (_, nxt_eng) <- stepForward Tick start_eng
  go nxt_eng
  where
    go eng = do
        msg <- receiveWait
          [ match (return . Left)
          , matchAny (return . Right)
          ]
        case msg of
          Left sub -> do
            (_, nxt_eng) <- stepForward (NewSub sub) eng
            go nxt_eng
          Right m -> do
            (_, nxt_eng) <- stepForward (Incoming m) eng
            go nxt_eng

incoming :: Serializable a => a -> Tick RunInfo
incoming = Incoming . wrapMessage

subscribeRequest :: Serializable a => ProcessId -> proxy a -> Tick ()
subscribeRequest pid p = NewSub $ newSubscribeRequest pid p

data Some f = forall a. Some (f a)

feedEngine :: [Some Tick] -> Engine -> Process ([RunInfo], Engine)
feedEngine msgs = go msgs []
  where
    go :: [Some Tick] -> [RunInfo] -> Engine -> Process ([RunInfo], Engine)
    go [] is end = return (reverse is, end)
    go (Some msg:rest) is cur = do
        case msg of
          Tick -> do
            (i, nxt) <- stepForward Tick cur
            go rest (i : is) nxt
          Incoming msg -> do
            (i, nxt) <- stepForward (Incoming msg) cur
            go rest (i : is) nxt
          _ -> do
            (_, nxt) <- stepForward msg cur
            go rest is nxt

-- | Holds type information used for later type message desarialization.
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

-- | Rule state data structure.
data RuleData g =
    RuleData
    { _ruleDataName :: !String
      -- ^ Rule name.
    , _ruleStack :: !(StackSM g)
      -- ^ Rule stack of execution.
    , _ruleTypes :: !(Set.Set TypeInfo)
      -- ^ All the 'TypeInfo' gathered while running rule state machine. It's
      --   only used at the CEP engine initialization phase, when calling
      --   'buildMachine'.
    }

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

-- | Builds a list of 'TypeInfo' out types needed by 'PhaseStep' data
--   contructor.
buildSeqList :: Seq -> Set.Set TypeInfo
buildSeqList Nil = Set.empty
buildSeqList (Cons (prx :: Proxy a) rest) =
    let i = TypeInfo (fingerprint (undefined :: a)) prx in
    Set.insert i $ buildSeqList rest

--  | Builds a list of 'TypeInfo' out types need by 'Phase's.
buildTypeList :: Foldable f => f (Phase g l) -> Set.Set TypeInfo
buildTypeList = foldr go Set.empty
  where
    go (Phase _ call) is =
        case call of
          ContCall (typ :: PhaseType g l a b) _ ->
            case typ of
              PhaseSeq sq _ -> Set.union (buildSeqList sq) is
              _ ->
                let i = TypeInfo (fingerprint (undefined :: a))
                                 (Proxy :: Proxy a) in
                Set.insert i is
          _ -> is

-- | Executes a rule state machine in order to produce a rule state data
--   structure.
buildRuleData :: String
              -> RuleM g l (Started g l)
              -> Buffer
              -> Maybe SMLogs
              -> RuleData g
buildRuleData name rls buf logs = go M.empty Set.empty $ view rls
  where
    go ps tpes (Return (StartingPhase l p)) =
        RuleData
        { _ruleDataName = name
        , _ruleStack    = newStackSM name p logs ps buf l
        , _ruleTypes    = Set.union tpes $ buildTypeList ps
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
        go ps (Set.insert tpe tpes) $ view $ k tok

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
notifySubscribers :: Serializable a => Subscribers -> a -> Process ()
notifySubscribers subs a = do
    self <- getSelfPid
    for_ (MM.lookup (fingerprint a) subs) $ \pid ->
      usend pid (Published a self)

data PhaseBufAction = CopyThatBuffer Buffer | CreateNewBuffer

data SpawnSM g l = SpawnSM PhaseBufAction l (PhaseM g l ())

data StackIn g = StackIn Subscribers g Input

data StackOut g =
    StackOut
    { _soGlobal    :: !g
    , _soExeReport :: !ExecutionReport
    , _soResult    :: !StackResult
    }

data StackResult = EmptyStack | NeedMore deriving Show

newtype StackSM g = StackSM (StackIn g -> Process (StackOut g, StackSM g))

data StackCtx g l = StackNormal (Phase g l) | StackSwitch [Phase g l]

infoTarget :: StackCtx g l -> Either String [String]
infoTarget (StackNormal ph)  = Left $ _phName ph
infoTarget (StackSwitch phs) = Right $ fmap _phName phs

data StackPhaseInfo
    = StackSinglePhase String
    | StackSwitchPhase String [String]
    deriving Show

stackPhaseInfoPhaseName :: StackPhaseInfo -> String
stackPhaseInfoPhaseName (StackSinglePhase n)   = n
stackPhaseInfoPhaseName (StackSwitchPhase n _) = n

data ExecutionFail = SuspendExe deriving Show

data ExecutionReport =
    ExecutionReport
    { exeSpawnSMs :: !Int
    , exeTermSMs  :: !Int
    , exeInfos    :: ![ExecutionInfo]
    } deriving Show

data ExecutionInfo
    = SuccessExe
      { exeInfoPhase :: !StackPhaseInfo
      }
    | FailExe
      { exeInfoTarget :: !(Either String [String])
      , exeInfoFail   :: !ExecutionFail
      }
    deriving Show

data StackCtxResult g l
    = StackDone StackPhaseInfo g [SpawnSM g l] [Phase g l] (SM g l)
    | StackSuspend (StackCtx g l)

data StackSlot g l
    = OnMainSM (StackCtx g l)
    | OnChildSM (SM g l) (StackCtx g l)

newStackSM :: String
           -> Phase g l
           -> Maybe SMLogs
           -> M.Map String (Phase g l)
           -> Buffer
           -> l
           -> StackSM g
newStackSM rn sp logs ps buf l =
    StackSM (mainStackSM rn sp logs ps buf l)

mainStackSM :: forall g l. String       -- Rule name.
            -> Phase g l                -- Starting phase.
            -> Maybe SMLogs             -- If we collect logs.
            -> M.Map String (Phase g l) -- Rule phases.
            -> Buffer                   -- Init buffer (when forking new SM).
            -> l                        -- Local state.
            -> StackIn g
            -> Process (StackOut g, StackSM g)
mainStackSM name sp logs ps init_buf sl = go [] (newSM init_buf logs sl)
  where
    go [] sm i                  = go [OnMainSM (StackNormal sp)] sm i
    go xs sm (StackIn subs g i) =
        case i of
          NoMessage -> executeStack subs sm g 0 0 [] [] xs
          GotMessage (TypeInfo _ (_ :: Proxy a)) msg -> do
            Just (a :: a) <- unwrapMessage msg
            let input = PushMsg a
            broadcast subs input xs sm g

    broadcast subs i xs sm g = do
        (SM_Unit, nxt_sm) <- unSM sm i
        xs' <- for xs $ \slot ->
          case slot of
            OnMainSM _       -> return slot
            OnChildSM lsm ph -> do
              (SM_Unit, nxt_lsm) <- unSM lsm i
              return $ OnChildSM nxt_lsm ph

        executeStack subs nxt_sm g 0 0 [] [] xs'

    executeStack :: Subscribers
                 -> SM g l
                 -> g
                 -> Int -- Spawn SMs
                 -> Int -- Terminated SMs
                 -> [ExecutionInfo]
                 -> [StackSlot g l]
                 -> [StackSlot g l]
                 -> Process (StackOut g, StackSM g)
    executeStack _ sm g ssms tsms rp done [] =
        let res = if null done then EmptyStack else NeedMore
            eis = reverse rp
            rep = ExecutionReport ssms tsms eis in
        return (StackOut g rep res, StackSM $ go (reverse done) sm)
    executeStack subs sm g ssms tsms rp done (x:xs) =
        case x of
          OnMainSM ctx -> do
            res <- contextStack subs sm g ctx
            case res of
              StackDone pinfo g' ss phs nxt_sm -> do
                phsm <- createSlots OnMainSM phs
                let ssm    = spawnSMs ss
                    jobs   = phsm ++ ssm
                    n_ssms = ssms + length ssm
                    r      = SuccessExe pinfo
                executeStack subs nxt_sm g' n_ssms tsms (r:rp) done
                                                                  (xs ++ jobs)
              StackSuspend new_ctx ->
                let slot = OnMainSM new_ctx
                    r    = FailExe (infoTarget ctx) SuspendExe in
                executeStack subs sm g ssms tsms (r:rp) (slot:done) xs
          OnChildSM lsm ctx -> do
            res <- contextStack subs lsm g ctx
            case res of
              StackDone pinfo g' ss phs nxt_lsm -> do
                phsm <- createSlots (OnChildSM nxt_lsm) phs
                let ssm    = spawnSMs ss
                    n_tsms = if null phs then tsms + 1 else tsms
                    n_ssms = length ssm + ssms
                    jobs   = phsm ++ ssm
                    r      = SuccessExe pinfo
                executeStack subs sm g' n_ssms n_tsms (r:rp) done (xs ++ jobs)
              StackSuspend new_ctx ->
                let slot = OnChildSM lsm new_ctx
                    r    = FailExe (infoTarget ctx) SuspendExe in
                executeStack subs sm g ssms tsms (r:rp) (slot:done) xs

    contextStack :: Subscribers
                 -> SM g l
                 -> g
                 -> StackCtx g l
                 -> Process (StackCtxResult g l)
    contextStack subs sm g ctx@(StackNormal ph) = do
        (out, nxt_sm) <- unSM sm (Execute subs g ph)
        let pinfo = StackSinglePhase $ _phName ph
        case out of
          SM_Complete g' _ ss hs -> do
            phs <- phases hs
            return $ StackDone pinfo g' ss phs nxt_sm
          SM_Suspend -> return $ StackSuspend ctx
          SM_Stop    -> return $ StackDone pinfo g [] [] sm
    contextStack subs sm g (StackSwitch xs) =
        let loop done []     = return $ StackSuspend
                                      $ StackSwitch (reverse done)
            loop done (a:as) = do
              let input = Execute subs g a
              (out, nxt_sm) <- unSM sm input
              case out of
                SM_Complete g' _ ss hs -> do
                  phs <- phases hs
                  let pname = _phName a
                      pas   = fmap _phName $ reverse done
                      pinfo = StackSwitchPhase pname pas
                  return $ StackDone pinfo g' ss phs nxt_sm
                SM_Suspend -> loop (a:done) as
                SM_Stop    -> loop done as
        in loop [] xs

    phases hs = for hs $ \h ->
        case M.lookup (_phHandle h) ps of
          Just ph -> return ph
          Nothing -> fail $ "impossible: rule " ++ name
                          ++ " doesn't have a phase named " ++ _phHandle h

    spawnSMs xs =
        let spawnIt (SpawnSM tpe l action) =
              let tmp_buf =
                    case tpe of
                      CopyThatBuffer buf -> buf
                      CreateNewBuffer    -> init_buf
                  fsm = newSM tmp_buf logs l
                  phc  = DirectCall action
                  ctx  = StackNormal $ Phase (name ++ "-child") phc in
              OnChildSM fsm ctx in
        fmap spawnIt xs

    createSlots :: (StackCtx g l -> StackSlot g l)
                -> [Phase g l]
                -> Process [StackSlot g l]
    createSlots mk phs =
        case phs of
          []  -> return []
          [x] -> return [mk $ StackNormal x]
          xs  -> return [mk $ StackSwitch xs]

data SM_Exe

data SM_In g l a where
    PushMsg :: Typeable m => m -> SM_In g l ()
    Execute :: Subscribers -> g -> (Phase g l) -> SM_In g l SM_Exe

data SM_Out g l a where
    SM_Complete :: g -> l -> [SpawnSM g l] -> [PhaseHandle] -> SM_Out g l SM_Exe
    SM_Suspend  :: SM_Out g l SM_Exe
    SM_Stop     :: SM_Out g l SM_Exe
    SM_Unit     :: SM_Out g l ()

smLocalState :: SM_Out g l a -> Maybe l
smLocalState (SM_Complete _ l _ _) = Just l
smLocalState _                     = Nothing

-- | Phase Mealy finite state machine.
newtype SM g l =
    SM { unSM :: forall a. SM_In g l a -> Process (SM_Out g l a, SM g l) }

newSM :: Buffer -> Maybe SMLogs -> l -> SM g l
newSM buf logs l = SM $ mainSM buf logs l

-- | Execute a 'Phase' state machine. If it's 'DirectCall' 'Phase', it's runned
--   directly. If it's 'ContCall' one, we make sure we can satisfy its
--   dependency. Otherwise, we 'Suspend' that phase.
mainSM :: Buffer
       -> Maybe SMLogs
       -> l
       -> SM_In g l a
       -> Process (SM_Out g l a, SM g l)
mainSM buf logs l (PushMsg msg) =
    let new_buf = bufferInsert msg buf in
    return (SM_Unit, SM $ mainSM new_buf logs l)
mainSM buf logs l (Execute subs g ph) =
    case _phCall ph of
      DirectCall action -> do
        (new_buf, out) <- runSM (_phName ph) subs buf g l [] logs action
        let final_buf =
              case out of
                SM_Suspend -> buf
                SM_Stop    -> buf
                _          -> new_buf
            nxt_l = fromMaybe l $ smLocalState out
        return (out, SM $ mainSM final_buf logs nxt_l)
      ContCall tpe k -> do
        res <- extractMsg tpe g l buf
        case res of
          Just (Extraction new_buf b) -> do
            notifySubscribers subs b
            let name = _phName ph
            (lastest_buf, out) <- runSM name subs new_buf g l [] logs (k b)
            let final_buf =
                  case out of
                    SM_Suspend -> buf
                    SM_Stop    -> buf
                    _          -> lastest_buf
                nxt_l = fromMaybe l $ smLocalState out
            case out of
              SM_Complete{} -> notifySubscribers subs b
              _             -> return ()
            return (out, SM $ mainSM final_buf logs nxt_l)
          Nothing -> return (SM_Suspend, SM $ mainSM buf logs l)

-- | 'Phase' state machine execution main loop. Runs until its stack is empty
--   except if get a 'Suspend' or 'Stop' instruction.
runSM :: String
      -> Subscribers
      -> Buffer
      -> g
      -> l
      -> [SpawnSM g l]
      -> Maybe SMLogs
      -> PhaseM g l ()
      -> Process (Buffer, SM_Out g l SM_Exe)
runSM pname subs buf g l stk logs action = viewT action >>= go
  where
    go (Return _) = return (buf, SM_Complete g l (reverse stk) [])
    go (Continue ph :>>= _) = return (buf, SM_Complete g l (reverse stk) [ph])
    go (Save s :>>= k) = runSM pname subs buf s l stk logs $ k ()
    go (Load :>>= k) = runSM pname subs buf g l stk logs $ k g
    go (Get Global :>>= k) = runSM pname subs buf g l stk logs $ k g
    go (Get Local :>>= k) = runSM pname subs buf g l stk logs $ k l
    go (Put Global s :>>= k) = runSM pname subs buf s l stk logs $ k ()
    go (Put Local l' :>>= k) = runSM pname subs buf g l' stk logs $ k ()
    go (Stop :>>= _) = return (buf, SM_Stop)
    go (Fork typ naction :>>= k) =
        let bufAction =
              case typ of
                NoBuffer   -> CreateNewBuffer
                CopyBuffer -> CopyThatBuffer buf

            ssm = SpawnSM bufAction l naction in
        runSM pname subs buf g l (ssm : stk) logs $ k ()
    go (Lift m :>>= k) = do
        a <- m
        runSM pname subs buf g l stk logs $ k a
    go (Suspend :>>= _) = return (buf, SM_Suspend)
    go (Publish e :>>= k) = do
        notifySubscribers subs e
        runSM pname subs buf g l stk logs $ k ()
    go (PhaseLog ctx lg :>>= k) =
        let new_logs = fmap (S.|> (pname,ctx,lg)) logs in
        runSM pname subs buf g l stk new_logs $ k ()
    go (Switch xs :>>= _) = return (buf, SM_Complete g l (reverse stk) xs)
    go (Peek idx :>>= k) = do
        case bufferPeek idx buf of
          Nothing -> return (buf, SM_Suspend)
          Just r  -> runSM pname subs buf g l stk logs $ k r
    go (Shift idx :>>= k) =
        case bufferGetWithIndex idx buf of
          (Nothing, _)   -> return (buf, SM_Suspend)
          (Just r, buf') -> runSM pname subs buf' g l stk logs $ k r

-- | Subscribes for a specific type of event. Every time that event occures,
--   this 'Process' will receive a 'Published a' message.
subscribe :: forall a proxy. Serializable a
          => ProcessId
          -> proxy a
          -> Process ()
subscribe pid _ = do
    self <- getSelfPid
    let key  = fingerprint (undefined :: a)
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
