{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- Complex Event Processing API
-- It builds a 'Process' out of rules defined by the user. It also support
-- pub/sub feature.
module Network.CEP
    (
    -- * Specification API
      PhaseM
    , RuleM
    , Definitions
    , Specification
    , Token
    , Scope(..)
    , ForkType(..)
    , Logs(..)
    , PhaseHandle
    , Started
    , wants
    , directly
    , setPhase
    , setPhaseIf
    , setPhaseWire
    , setPhaseMatch
    , setPhaseSequenceIf
    , setPhaseSequence
    , phaseHandle
    , start
    , start_
    , get
    , put
    , modify
    , continue
    , stop
    , switch
    , fork
    , suspend
    , publish
    , phaseLog
    , peek
    , shift
    , liftProcess
    , define
    , initRule
    , defineSimple
    , defineSimpleIf
    , setLogger
    , setRuleFinalizer
    , setBuffer
    , enableDebugMode
    -- * Buffer
    , Buffer
    , Index
    , FIFOType(..)
    , initIndex
    , fifoBuffer
    , emptyFifoBuffer
    -- * Engine
    , Engine
    , cepEngine
    , execute
    , runItForever
    , stepForward
    , feedEngine
    , incoming
    , tick
    -- * Subscription
    , Published(..)
    , subscribeRequest
    , subscribe
    -- * Misc
    , Some(..)
    , occursWithin
    -- * Re-export
    , module Network.CEP.Execution
    ) where

import           Control.Monad
import           Data.Dynamic
import           Data.Foldable (for_)

import           Control.Distributed.Process hiding (call)
import           Control.Distributed.Process.Internal.Types
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import           Control.Wire (mkPure)
import qualified Data.MultiMap   as MM
import qualified Data.Map.Strict as M
import qualified Data.Sequence   as S
import qualified Data.Set        as Set
import           Data.Time
import           FRP.Netwire (dtime)

import Network.CEP.Buffer
import Network.CEP.Engine
import Network.CEP.Execution
import Network.CEP.SM
import Network.CEP.Types
import Network.CEP.Utils

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
buildMachine :: s -> Specification s () -> Machine s
buildMachine s defs = go (emptyMachine s) $ view defs
  where
    go :: Machine s -> ProgramView (Declare s) () -> Machine s
    go st (Return _) = fillMachineTypeMap st
    go st (DefineRule n m :>>= k) =
        let logs = fmap (const S.empty) $ _machLogger st
            idx = _machRuleCount st
            key = RuleKey idx n
            dat = buildRuleData n newSM m (_machPhaseBuf st) logs
            mp  = M.insert key dat $ _machRuleData st
            st' = st { _machRuleData  = mp
                     , _machRuleCount = idx + 1
                     } in
        go st' $ view $ k ()
    go st (Init m :>>= k) =
        let logs = fmap (const S.empty) $ _machLogger st
            dat  = buildRuleData "init" newSM m (_machPhaseBuf st) logs
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
cepEngine :: s -> Specification s () -> Engine
cepEngine s defs = newEngine $ buildMachine s defs

-- | Executes a CEP Specification to the 'Process' monad given a initial global
--   state.
execute :: s -> Specification s () -> Process ()
execute s defs = runItForever $ cepEngine s defs

-- | A CEP 'Engine' driver that run an 'Engine' until the end of the universe.
runItForever :: Engine -> Process ()
runItForever start_eng = do
  let debug_mode = stepForward debugModeSetting start_eng
  bootstrap debug_mode [] (1 :: Integer) start_eng
  where
    bootstrap debug_mode ms 1 eng = do
      (ri, nxt_eng) <- stepForward tick eng
      let init_done = stepForward initRulePassedSetting nxt_eng
      when debug_mode . liftIO $ dumpDebuggingInfo Tick 1 ri
      if init_done
        then do
          when debug_mode $ liftIO $ do
            putStrLn "<~~~~~~~~~~ INIT RULE FINISHED ~~~~~~~~~~>"
          cruise debug_mode 2 nxt_eng
        else bootstrap debug_mode ms 2 nxt_eng
    bootstrap debug_mode ms loop eng = do
      msg <- receiveWait
               [ match (return . Left . rawSubRequest)
               , matchAny (return . Right . rawIncoming)
               ]
      case msg of
        Left sub -> do
          (_, nxt_eng) <- stepForward sub eng
          bootstrap debug_mode ms (succ loop) nxt_eng
        Right m -> do
          let act' = requestAction m
          (ri', nxt_eng') <- stepForward m eng
          when debug_mode . liftIO $ dumpDebuggingInfo act' loop ri'
          let act = requestAction (Run Tick)
          (ri, nxt_eng) <- stepForward (Run Tick) nxt_eng'
          when debug_mode . liftIO $ dumpDebuggingInfo act loop ri
          case runResult ri' of
            MsgIgnored ->
              bootstrap debug_mode (m:ms) (succ loop) nxt_eng
            _ -> do
              let init_done = stepForward initRulePassedSetting nxt_eng
              when (init_done && debug_mode) $ liftIO $ do
                putStrLn "<~~~~~~~~~~ INIT RULE FINISHED ~~~~~~~~~~>"
              if init_done
                then if null ms
                  then cruise debug_mode (succ loop) nxt_eng
                  else
                    let lefts = reverse ms in
                    forwardLeftOvers debug_mode (succ loop) nxt_eng lefts
                else bootstrap debug_mode ms (succ loop) nxt_eng
    forwardLeftOvers debug_mode loop eng [] =
      cruise debug_mode loop eng
    forwardLeftOvers debug_mode loop eng (x:xs) = do
      (ri, nxt_eng) <- stepForward x eng
      let act = requestAction x
      when debug_mode . liftIO $ dumpDebuggingInfo act loop ri
      forwardLeftOvers debug_mode (succ loop) nxt_eng xs

    cruise debug_mode loop eng
      | stepForward engineIsRunning eng =
        go eng =<< receiveTimeout 0 [ match (return . Left . rawSubRequest)
                                    , matchAny (return . Right . rawIncoming)
                                    ]
      | otherwise =
        go eng . Just =<< receiveWait [ match (return . Left . rawSubRequest)
                                      , matchAny (return . Right . rawIncoming)
                                      ]
      where
        go inner (Just (Left sub)) = do
          (_, nxt_eng) <- stepForward sub inner
          cruise debug_mode (succ loop) nxt_eng
        go inner (Just (Right m))  = do
          (ri, nxt_eng) <- stepForward m inner
          let act = requestAction m
          when debug_mode . liftIO $ dumpDebuggingInfo act loop ri
          go nxt_eng Nothing
        go inner Nothing = do
          (ri, nxt_eng) <- stepForward tick inner
          let act = requestAction tick
          when debug_mode . liftIO $ dumpDebuggingInfo act loop ri
          cruise debug_mode (succ loop) nxt_eng

dumpDebuggingInfo :: Action RunInfo -> Integer -> RunInfo -> IO ()
dumpDebuggingInfo m loop (RunInfo total rres) = do
    putStrLn $ "===== CEP loop " ++ show loop ++ " ====="
    putStrLn $ "Total processed messages: " ++ show total
    case rres of
      MsgIgnored -> do
        let Incoming i = m
        putStrLn $ "Message IGNORED: " ++ show (messageFingerprint i)
      RulesBeenTriggered ris -> do
        putStrLn $ "Number of triggered rules: " ++ show (length ris)
                 ++ "\n"
        for_ ris $ \(RuleInfo rname rep) -> do
          let nstr =
                case rname of
                  InitRuleName -> "$$INIT_RULE$$"
                  RuleName s   -> s
          putStrLn $ "----- |" ++ nstr ++ "| rule -----\n"
          putStrLn $ "-> Number of new spawn SMs: " ++ show (length rep - 1)
          for_ (zip [1..] rep) $ \(i, (stk, einfo)) -> do
            putStrLn $ "Machine #" ++ show (i::Int)
            putStrLn $ case stk of
              SMFinished  -> "Stack state: " ++ show stk ++ " (SM finished execution.)"
              SMRunning   -> "Stack state: " ++ show stk ++ " (SM continue execution to the next state.)"
              SMSuspended -> "Stack state: " ++ show stk ++ " (SM suspended execution.)"
              SMStopped   -> "Stack state: " ++ show stk ++ " (SM have stopped.)"
            putStrLn "Execution logs:"
            for_ (zip [1..] einfo) $ \(j,e) -> do
              putStrLn $ "Step" ++ show (j::Int) ++ ":"
              case e of
                SuccessExe pif p_buf buf -> do
                  putStrLn $ "<" ++ pif ++ ">"
                  putStrLn "___ Execution result: SUCCESS"
                  case p_buf == buf of
                    True  -> putStrLn "___ Buffer is untounched"
                    False -> do
                      putStrLn $ "___ Previous buffer: " ++ show p_buf
                      putStrLn $ "___ Resulted buffer: " ++ show buf
                FailExe tgt r buf -> do
                  putStrLn $ "     <" ++ tgt ++ ">\n"
                  case r of
                    SuspendExe -> putStrLn "___ Execution result: SUSPEND"
                    StopExe    -> putStrLn "___ Execution result: STOP"
                  putStrLn $ "___ buffer " ++ show buf
    putStrLn $ "#### CEP loop " ++ show loop ++ " #####"

incoming :: Serializable a => a -> Request 'Write (Process (RunInfo, Engine))
incoming = Run . Incoming . wrapMessage

subscribeRequest :: Serializable a
                 => ProcessId
                 -> proxy a
                 -> Request 'Write (Process ((), Engine))
subscribeRequest pid p = Run . NewSub $ newSubscribeRequest pid p

feedEngine :: [Some (Request 'Write)] -> Engine -> Process ([RunInfo], Engine)
feedEngine msgs = go msgs []
  where
    go :: [Some (Request 'Write)]
       -> [RunInfo]
       -> Engine
       -> Process ([RunInfo], Engine)
    go [] is end = executeEngine is end
    go (Some req@(Run t):rest) is cur = do
        case t of
          Tick -> do
            (i, nxt) <- stepForward req cur
            go rest (i : is) nxt
          Incoming _ -> do
            (i, nxt) <- stepForward req cur
            go rest (i : is) nxt
          _ -> do
            (_, nxt) <- stepForward req cur
            go rest is nxt
    executeEngine rs eng
      | stepForward engineIsRunning eng = do
          (r, eng') <- stepForward tick eng
          executeEngine (r:rs) eng'
      | otherwise = return (reverse rs, eng)


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
              -> (Phase g l -> String -> Maybe SMLogs -> M.Map String (Phase g l) -> Buffer -> l -> SM g)
              -> RuleM g l (Started g l)
              -> Buffer
              -> Maybe SMLogs
              -> RuleData g
buildRuleData name mk rls buf logs = go M.empty Set.empty $ view rls
  where
    go ps tpes (Return (StartingPhase l p)) =
        RuleData
        { _ruleDataName = name
        , _ruleStack    = mk p name logs ps buf l
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
