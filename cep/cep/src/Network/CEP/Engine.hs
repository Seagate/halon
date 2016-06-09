{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE GADTs           #-}
{-# LANGUAGE KindSignatures  #-}
{-# LANGUAGE Rank2Types      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections   #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
module Network.CEP.Engine where

import Data.Maybe
import Data.Traversable (for)
import Data.Foldable (for_)
import Data.Either (partitionEithers)

import           Control.Distributed.Process hiding (bracket_)
import           Control.Distributed.Process.Internal.Types
import           Control.Distributed.Process.Serializable
import qualified Control.Monad.Trans.State.Strict as State
import           Control.Monad.Trans
import           Control.Monad.Catch (bracket_)
import qualified Data.MultiMap       as MM
import qualified Data.Map.Strict     as M
import qualified Data.Sequence       as S
import qualified Data.Set            as Set
import           Data.Traversable (mapAccumL)
import           Data.Foldable (forM_)
import           Debug.Trace (traceEventIO)

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.SM
import Network.CEP.Types

data Input
    = NoMessage
    | GotMessage TypeInfo Message

-- | Rule state data structure.
data RuleData g =
    RuleData
    { _ruleDataName :: !String
      -- ^ Rule name.
    , _ruleStack :: !(SM g)
      -- ^ Rule stack of execution.
    , _ruleTypes :: !(Set.Set TypeInfo)
      -- ^ All the 'TypeInfo' gathered while running rule state machine. It's
      --   only used at the CEP engine initialization phase, when calling
      --   'buildMachine'.
    }

data Mode = Read | Write | Execute

-- | Represents the type of request a CEP 'Engine' can handle.
--
-- 'Query': Read request that doesn't update CEP 'Engine' internal
-- state.
--
-- 'Run': Write request that might update CEP 'Engine' internal state.
--
-- 'DefaultAction': Run default handler for unprocessed message.
data Request :: Mode -> * -> * where
    Query :: Select a -> Request 'Read a
    Run :: Action a -> Request 'Write (Process (a, Engine))
    DefaultAction :: Message -> Request 'Execute (Process ())

data Select a = GetSetting (EngineSetting a)
                -- ^ Get CEP 'Engine' internal setting.

data Action a where
    Tick           :: Action RunInfo
    Incoming       :: Message   -> Action RunInfo
    NewSub         :: Subscribe -> Action ()
    TimeoutArrived :: Timeout -> Action RunInfo

data EngineSetting a where
    EngineDebugMode      :: EngineSetting Bool
    EngineInitRulePassed :: EngineSetting Bool
    EngineIsRunning      :: EngineSetting Bool

initRulePassedSetting :: Request 'Read Bool
initRulePassedSetting = Query $ GetSetting EngineInitRulePassed

debugModeSetting :: Request 'Read Bool
debugModeSetting = Query $ GetSetting EngineDebugMode

engineIsRunning :: Request 'Read Bool
engineIsRunning = Query $ GetSetting EngineIsRunning

tick :: Request 'Write (Process (RunInfo, Engine))
tick = Run Tick

rawSubRequest :: Subscribe -> Request 'Write (Process ((), Engine))
rawSubRequest = Run . NewSub

rawIncoming :: Message -> Request 'Write (Process (RunInfo, Engine))
rawIncoming = Run . Incoming

timeoutMsg :: Timeout -> Request 'Write (Process (RunInfo, Engine))
timeoutMsg = Run . TimeoutArrived

requestAction :: Request 'Write (Process (a, Engine)) -> Action a
requestAction (Run a) = a

runDefaultHandler :: Message -> Request 'Execute (Process ())
runDefaultHandler = DefaultAction


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

-- | Main CEP engine state structure.
data Machine s =
    Machine
    { _machRuleData :: !(M.Map RuleKey (RuleData s))
      -- ^ Rules defined by the users.
    , _machSubs :: !Subscribers
      -- ^ Subscribers interested in events issued by this CEP engine.
    , _machLogger :: !(Maybe (Logs -> s -> Process ()))
      -- ^ Logger callback.
    , _machRuleFin :: !(Maybe (s -> Process s))
      -- ^ Callback used when a rule has completed.
    , _machRuleCount :: !Int
      -- ^ It will get you the number of rules that CEP engine handles. but
      --   it's use to order rule by order in appearence when generating
      --   'RuleKey'.
    , _machPhaseBuf :: !Buffer
      -- ^ Default buffer when forking a new 'Phase' state machine.
    , _machTypeMap :: !(MM.MultiMap Fingerprint (RuleKey, TypeInfo))
      -- ^ Keep track of every rule interested in a certain message type.
      --   It also keeps type information that helpful for deserializing.
    , _machState :: !s
      -- ^ CEP engine global state.
    , _machDebugMode :: !Bool
      -- ^ Set the CEP engine in debug mode, dumping more internal log to the
      --   the terminal.
    , _machInitRule :: !(Maybe (InitRule s))
      -- ^ Rule to run at 'InitStep' step.
    , _machTotalProcMsgs :: !Int
    , _machInitRulePassed :: !Bool
      -- ^ Indicates the if the init rule has been executed already.
    , _machRunningSM :: [(RuleKey, RuleData s)]
      -- ^ List of SM that is in a runnable state
    , _machSuspendedSM :: [(RuleKey, RuleData s)]
      -- ^ List of SM that are in suspended state
    , _machDefaultHandler :: !(Maybe (Message -> s -> Process ()))
    }

-- | Creates CEP engine state with default properties.
emptyMachine :: s -> Machine s
emptyMachine s =
    Machine
    { _machRuleData       = M.empty
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
    , _machSuspendedSM    = []
    , _machDefaultHandler = Nothing
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
defaultHandler st next (Run (TimeoutArrived _)) =
    return (RunInfo (_machTotalProcMsgs st) MsgIgnored, Engine $ next st)
defaultHandler st _ (DefaultAction msg) =
    forM_ (_machDefaultHandler st) $ \f -> f msg (_machState st)
defaultHandler st _ (Query (GetSetting s)) =
    case s of
      EngineDebugMode      -> _machDebugMode st
      EngineInitRulePassed -> _machInitRulePassed st
      EngineIsRunning      -> not (null (_machRunningSM st))

interestingMsg :: (Fingerprint -> Bool) -> Message -> Bool
interestingMsg k msg = k $ messageFingerprint msg

foreach :: Functor f => f a -> (a -> b) -> f b
foreach xs f = fmap f xs

cepInitRule :: InitRule g -> Machine g -> Request m a -> a
cepInitRule ir@(InitRule rd typs) st@Machine{..} req@(Run i) = do
    case i of
      Tick -> go NoMessage _machTotalProcMsgs
      TimeoutArrived (Timeout k)
        | k == initRuleKey -> go NoMessage _machTotalProcMsgs
        | otherwise        -> defaultHandler st (cepInitRule ir) req
      Incoming m@((`M.lookup` typs) . messageFingerprint -> Just tpe) ->
          let msg       = GotMessage tpe m
              msg_count = _machTotalProcMsgs + 1 in
          go msg msg_count
      Incoming _ -> defaultHandler st (cepInitRule ir) req
      _ -> defaultHandler st (cepInitRule ir) req
  where
    go (GotMessage ty m) msg_count = do
      let stack' = runSM (_ruleStack rd) (SMMessage ty m)
          -- XXX: update runinfo
          rinfo = RunInfo 0 (RulesBeenTriggered [])
      return (rinfo, Engine $ cepInitRule (InitRule rd{_ruleStack=stack'} typs)
                                          st{ _machTotalProcMsgs = msg_count })
    go NoMessage msg_count = do
      let stk  = _ruleStack rd
          logs = fmap (const S.empty) _machLogger
          exe  = SMExecute logs _machSubs
      -- We do not allow fork inside init rule, this may be ok or not
      -- depending on a usecase, but allowing fork will make implementation
      -- much harder and do not worth it, unless we have a concrete example.
      ([(SMResult out infos mlogs, nxt_stk)], g) <-
          State.runStateT (runSM stk exe) _machState
      let new_rd = rd { _ruleStack = nxt_stk }
          nxt_st = st { _machState = g }
          rinfo = RuleInfo InitRuleName [(out, infos)]
          info  = RunInfo msg_count (RulesBeenTriggered [rinfo])
      for_ _machLogger $ \f -> for_ mlogs $ \l -> f l g
      case out of
        SMFinished -> do
          let final_st = nxt_st { _machInitRulePassed = True}
          return (info, Engine $ cepCruise final_st)
        SMRunning -> cepInitRule (InitRule new_rd typs) nxt_st (Run Tick)
        _ -> return (info, Engine $ cepInitRule (InitRule new_rd typs) nxt_st)
cepInitRule ir st req = defaultHandler st (cepInitRule ir) req

cepCruise :: Machine s -> Request m a -> a
cepCruise st req@(Run t) =
    case t of
      Tick -> do
        -- XXX: currently only runnable SM are started, so if rule has
        --      an effectfull requirements to pass this could be a problem
        --      for the rule.
        (infos, nxt_st) <- State.runStateT executeTick st
        let rinfo = RunInfo (_machTotalProcMsgs nxt_st) (RulesBeenTriggered infos)
        return (rinfo, Engine $ cepCruise nxt_st)
      TimeoutArrived (Timeout key) ->
          let xs     = filter (\(k,_) -> key == k) $ _machSuspendedSM st
              nxt_su = filter (\(k,_) -> key /= k) $ _machSuspendedSM st
              prev   = _machRunningSM st
              nxt_st = st { _machRunningSM   = prev ++ xs
                          , _machSuspendedSM = nxt_su }
              res    = RulesBeenTriggered []
              info   = RunInfo (_machTotalProcMsgs st) res in
          return (info, Engine $ cepCruise nxt_st)
      Incoming m | interestingMsg (MM.member (_machTypeMap st)) m -> do
        let fpt = messageFingerprint m
            keyInfos = MM.lookup fpt $ _machTypeMap st
            (upd,running') = mapAccumL
              (\u (key, rd) -> case key `lookup` keyInfos of
                 Just info ->
                   let stack' = runSM (_ruleStack rd) (SMMessage info m) in
                   (u+1, (key, rd{_ruleStack=stack'}))
                 Nothing   -> (u,(key,rd))) 0 (_machRunningSM st)
            splitted = foreach (_machSuspendedSM st) $ \(key, rd) ->
              case key `lookup` keyInfos of
                Just info ->
                  let stack' = runSM (_ruleStack rd) (SMMessage info m) in
                  Right (key, rd{_ruleStack=stack'})
                Nothing   -> Left (key, rd)
            (susp,running) = partitionEithers splitted
            rinfo = RunInfo (upd+length running)
              $ if upd+length running == 0
                  then MsgIgnored
                  else RulesBeenTriggered []
        return (rinfo, Engine $ cepCruise st{_machRunningSM   = running' ++ running
                                            ,_machSuspendedSM = susp
                                            })
      _ -> defaultHandler st cepCruise req
cepCruise st req = defaultHandler st cepCruise req

-- | Execute one step of the Engine.
executeTick :: State.StateT (Machine g) Process [RuleInfo]
executeTick = do
    running <- bootstrap
    info <- traverse (uncurry execute) running
    sti <- State.get
    g_opt <- for (_machRuleFin sti) $ \k -> lift $ k (_machState sti)
    for_ g_opt $ \g -> State.modify $ \n -> n{_machState=g}
    return info
  where
    bootstrap = do
      st <- State.get
      State.put st{_machRunningSM=[]}
      return (_machRunningSM st)
    execute key sm =
      bracket_ (liftIO $ traceEventIO $ "START cep:engine:execute:" ++ _ruleKeyName key)
               (liftIO $ traceEventIO $ "STOP cep:engine:execute:" ++ _ruleKeyName key)
               $ do
      sti <- State.get
      let logs = fmap (const S.empty) $ _machLogger sti
          exe  = SMExecute logs (_machSubs sti)
      (machines, g') <- lift $ State.runStateT (runSM (_ruleStack sm) exe) (_machState sti)
      let addRunning   = foldr (\x y -> mkRunningSM x . y) id machines
          addSuspended = foldr (\x y -> mkSuspendedSM x . y) id machines
          mkRunningSM (SMResult SMRunning  _ _, s) = (mkSM s :)
          mkRunningSM (SMResult SMFinished _ _, s) = (mkSM s :)
          mkRunningSM _  = id
          mkSuspendedSM (SMResult SMSuspended _ _, s) = (mkSM s :)
          mkSuspendedSM _ = id
          mkSM nxt_stk = (key, sm{_ruleStack=nxt_stk})
          mlogs  = mapMaybe (smResultLogs .fst) machines
      State.modify $ \nxt_st ->
        nxt_st{_machRunningSM = addRunning $ _machRunningSM nxt_st
              ,_machSuspendedSM = addSuspended $ _machSuspendedSM nxt_st
              }
      lift $ for_ (_machLogger sti) $ \f -> for_ mlogs $ \l -> f l g'
      return $ RuleInfo (RuleName $ _ruleDataName sm)
             $ map ((\(SMResult s r _) -> (s, r)) . fst) machines
