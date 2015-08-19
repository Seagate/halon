{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE GADTs           #-}
{-# LANGUAGE KindSignatures  #-}
{-# LANGUAGE Rank2Types      #-}
{-# LANGUAGE RecordWildCards #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.Engine where

import Data.Maybe
import Data.Traversable (for)
import Data.Foldable (forM_)

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types
import           Control.Distributed.Process.Serializable
import qualified Control.Monad.State as State
import           Control.Monad.Trans
import qualified Data.MultiMap       as MM
import qualified Data.Map.Strict     as M
import qualified Data.Set            as Set
import           FRP.Netwire (clockSession_)

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.Stack
import Network.CEP.StackDriver
import Network.CEP.Types

-- | Rule state data structure.
data RuleData g =
    RuleData
    { _ruleDataName :: !String
      -- ^ Rule name.
    , _ruleStack :: !(StackDriver g)
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

data Mode = Read | Write

-- | Represents the type of request a CEP 'Engine' can handle.
data Request :: Mode -> * -> * where
    Query :: Select a -> Request 'Read a
    -- ^ Read request that doesn't update CEP 'Engine' internal state.
    Run :: Action a -> Request 'Write (Process (a, Engine))
    -- ^ Write request that might update CEP 'Engine' internal state.

data Select a where
    GetSetting :: EngineSetting a -> Select a
    -- ^ Get CEP 'Engine' internal setting.

data Action a where
    Tick     :: Action RunInfo
    Incoming :: Message   -> Action RunInfo
    NewSub   :: Subscribe -> Action ()

data EngineSetting a where
    EngineDebugMode      :: EngineSetting Bool
    EngineInitRulePassed :: EngineSetting Bool

initRulePassedSetting :: Request 'Read Bool
initRulePassedSetting = Query $ GetSetting EngineInitRulePassed

debugModeSetting :: Request 'Read Bool
debugModeSetting = Query $ GetSetting EngineDebugMode

tick :: Request 'Write (Process (RunInfo, Engine))
tick = Run Tick

rawSubRequest :: Subscribe -> Request 'Write (Process ((), Engine))
rawSubRequest = Run . NewSub

rawIncoming :: Message -> Request 'Write (Process (RunInfo, Engine))
rawIncoming = Run . Incoming

requestAction :: Request 'Write (Process (a, Engine)) -> Action a
requestAction (Run a) = a

-- CEP Engine finit state machine represented as a Mealy machine.
newtype Engine = Engine { _unE :: forall a m. Request m a -> a }

stepForward :: Request m a -> Engine -> a
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
    , _machTotalProcMsgs :: !Int
    , _machInitRulePassed :: !Bool
      -- ^ Indicates the if the init rule has been executed already.
    , _machRunningSM :: [(RuleKey,RuleData s)]
    }

-- | Creates CEP engine state with default properties.
emptyMachine :: s -> Machine s
emptyMachine s =
    Machine
    { _machRuleData       = M.empty
    , _machSession        = clockSession_
    , _machSubs           = MM.empty
    , _machLogger         = Nothing
    , _machRuleFin        = Nothing
    , _machRuleCount      = 0
    , _machPhaseBuf       = fifoBuffer Unbounded
    , _machTypeMap        = MM.empty
    , _machState          = s
    , _machDebugMode      = False
    , _machInitRule       = Nothing
    , _machTotalProcMsgs  = 0
    , _machInitRulePassed = False
    , _machRunningSM      = []
    }

newEngine :: Machine s -> Engine
newEngine st = Engine $ cepInit st

cepInit :: Machine s -> Request m a -> a
cepInit st i =
    case _machInitRule st' of
      Nothing -> do
          let nxt_st = st' { _machInitRulePassed = True }
          cepCruise nxt_st i
      Just ir -> cepInitRule ir st' i
  where
    st' = st{_machRunningSM = M.assocs $ _machRuleData st}

cepSubRequest :: Machine g -> Subscribe -> Machine g
cepSubRequest st@Machine{..} (Subscribe tpe pid) = nxt_st
  where
    key      = decodeFingerprint tpe
    nxt_subs = MM.insert key pid _machSubs
    nxt_st   = st { _machSubs = nxt_subs }

defaultHandler :: Machine g
               -> (forall b n. Machine g -> Request n b -> b)
               -> Request m a
               -> a
defaultHandler st next (Run (NewSub sub)) =
    return ((), Engine $ next $ cepSubRequest st sub)
defaultHandler st next (Run Tick) =
    return (RunInfo (_machTotalProcMsgs st) MsgIgnored, Engine $ next st)
defaultHandler st next (Run (Incoming _)) =
    return (RunInfo (_machTotalProcMsgs st) MsgIgnored, Engine $ next st)
defaultHandler st _ (Query (GetSetting s)) =
    case s of
      EngineDebugMode      -> _machDebugMode st
      EngineInitRulePassed -> _machInitRulePassed st

interestingMsg :: (Fingerprint -> Bool) -> Message -> Bool
interestingMsg k msg = k $ messageFingerprint msg

cepInitRule :: InitRule g -> Machine g -> Request m a -> a
cepInitRule ir@(InitRule rd typs) st@Machine{..} req@(Run i) =
    case i of
      Tick -> go NoMessage _machTotalProcMsgs
      Incoming m
        | interestingMsg (\frp -> M.member frp typs) m ->
          let tpe       = typs M.! messageFingerprint m
              msg       = GotMessage tpe m
              msg_count = _machTotalProcMsgs + 1 in
          go msg msg_count
        | otherwise -> defaultHandler st (cepInitRule ir) req
      _ -> defaultHandler st (cepInitRule ir) req
  where
    go msg msg_count = do
      let stk = _ruleStack rd
      (out, nxt_stk) <- runStackDriver _machSubs _machState msg stk
      let StackOut g infos res mlogs = out
          new_rd = rd { _ruleStack = nxt_stk }
          nxt_st = st { _machState         = g
                      , _machTotalProcMsgs = msg_count
                      }
          rinfo = RuleInfo InitRuleName res infos
          info  = RunInfo msg_count (RulesBeenTriggered [rinfo])
      forM_ _machLogger $ \f -> forM_ mlogs $ \l -> f l g
      case res of
        EmptyStack -> do
          let final_st = nxt_st { _machInitRulePassed = True}
          return (info, Engine $ cepCruise final_st)
        _ -> return (info, Engine $ cepInitRule (InitRule new_rd typs) nxt_st)
cepInitRule ir st req = defaultHandler st (cepInitRule ir) req

cepCruise :: Machine s -> Request m a -> a
cepCruise st req@(Run t) =
    case t of
      Tick -> do
        let _F (k,r) = (k, r, NoMessage)
            tups     = fmap _F $ _machRunningSM st
        go tups (_machTotalProcMsgs st)
      Incoming m | interestingMsg (MM.member (_machTypeMap st)) m -> do
        let fpt = messageFingerprint m
            keyInfos = MM.lookup fpt $ _machTypeMap st
        tups <- for (_machRunningSM st) $ \(key, rd) -> do
                 case key `lookup` keyInfos of
                   Just info -> return (key, rd, GotMessage info m)
                   Nothing   -> return (key, rd, NoMessage)
        go tups (_machTotalProcMsgs st + 1)
      _ -> defaultHandler st cepCruise req
  where
    go tups msg_count = do
      let action = for tups $ \(key, rd, i) -> do
            tmp_st          <- State.get
            (rinfo, nxt_st) <- lift $ broadcastInput tmp_st key rd i
            g_opt <- for (_machRuleFin st) $ \k -> lift $ k $ _machState nxt_st
            let prev     = _machState nxt_st
                final_st = nxt_st { _machState = fromMaybe prev g_opt }
            State.put final_st
            return rinfo

      (infos, tmp_st) <- State.runStateT action st{_machRunningSM=[]}
      let nxt_st = tmp_st { _machTotalProcMsgs = msg_count }
          rinfo  = RunInfo msg_count (RulesBeenTriggered infos)
      return (rinfo, Engine $ cepCruise nxt_st)

    broadcastInput cur_st key rd i = do
      let ruleName = RuleName $ _ruleDataName rd
          subs     = _machSubs cur_st
          g        = _machState cur_st
      (out, nxt_stk) <- runStackDriver subs g i $ _ruleStack rd
      let StackOut nxt_g hi res mlogs = out
          nxt_rd  = rd { _ruleStack = nxt_stk }
          nxt_dts = (key, nxt_rd):_machRunningSM cur_st
          nxt_st  = cur_st { _machRunningSM = nxt_dts
                           , _machState     = nxt_g
                           }
          info = RuleInfo ruleName res hi
      forM_ (_machLogger st) $ \f -> forM_ mlogs $ \l -> f l nxt_g
      return (info, nxt_st)
cepCruise st req = defaultHandler st cepCruise req
