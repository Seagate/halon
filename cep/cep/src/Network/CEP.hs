{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
--
-- = Complex Event Processing API
--
-- Builds a 'Process' action out of rules defined by the user. It also provides
-- a publish/subscribe framework.

module Network.CEP
    (
    -- * Specification API
      Application(..)
    , PhaseM
    , RuleM
    , MonadProcess(..)
    , Definitions
    , Specification
    , Token
    , Scope(..)
    , ForkType(..)
    , Jump
    , PhaseHandle
    , Started
    , wants
    , directly
    , setPhase
    , setPhaseIf
    , setPhaseSequenceIf
    , setPhaseSequence
    , phaseHandle
    , start
    , start_
    , startFork
    , startForks
    , get
    , gets
    , put
    , modify
    , continue
    , stop
    , switch
    , fork
    , suspend
    , publish
    , appLog
    , peek
    , shift
    , define
    , initRule
    , defineSimple
    , defineSimpleIf
    , setLogger
    , setLocalStateLogger
    , setRuleFinalizer
    , setBuffer
    , setDefaultHandler
    , enableDebugMode
    , timeout
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
    , RuntimeInfoRequest(..)
    , RuntimeInfo(..)
    , MemoryInfo(..)
    -- * Subscription
    , Published(..)
    , subscribeRequest
    , subscribe
    , unsubscribe
    , subscribeThem
    , unsubscribeThem
    , rawSubscribeThem
    , rawUnsubscribeThem

    -- * Misc
    , Some(..)
    -- * Re-export
    , module Network.CEP.Execution
    ) where

import           Control.Monad
import           Data.Proxy
import           Data.Typeable
import           Data.Foldable (for_)

import           Control.Distributed.Process hiding (bracket_)
import           Control.Distributed.Process.Internal.Types
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.MultiMap as MM
import           Data.Set (Set)
import qualified Data.Set as Set

import Network.CEP.Buffer
import Network.CEP.Engine
import Network.CEP.Execution
import qualified Network.CEP.Log as Log
import Network.CEP.SM
import Network.CEP.Types
import Network.CEP.Utils
import Data.PersistMessage

import System.Clock
import Debug.Trace (traceMarkerIO)

-- | Fills type tracking map with every type of messages needed by the engine
--   rules.
fillMachineTypeMap :: Machine s -> Machine s
fillMachineTypeMap st@Machine{..} =
    st { _machTypeMap = M.foldrWithKey go MM.empty _machRuleData
       , _machSFingerprint = M.foldrWithKey gos M.empty _machRuleData
       }
  where
    go key rd m =
        let insertF i@(TypeInfo fprt _) = MM.insert fprt (key, i)
        in foldr insertF m $ _ruleTypes rd
    gos _key rd m =
        let insertF (TypeInfo fprt r) =
              M.insert (stableprintTypeRep $ typeRep r) fprt
        in foldr insertF m $ _ruleTypes rd

-- | Fills a type tracking map with every type of messages needed by the init
--   rule.
initRuleTypeMap :: RuleData s -> Map Fingerprint TypeInfo
initRuleTypeMap rd = foldr go M.empty $ _ruleTypes rd
  where
    go i@(TypeInfo fprt _) = M.insert fprt i

-- | Constructs a CEP engine state by using an initial global state value and a
--   definition state machine.
buildMachine :: forall app g. (Application app, g ~ GlobalState app)
             => g -> Specification app () -> Machine app
buildMachine s defs = go (emptyMachine s) $ view defs
  where
    go :: Machine app -> ProgramView (Declare app) () -> Machine app
    go st (Return _) = fillMachineTypeMap st
    go st (DefineRule n m :>>= k) =
        let idx = _machRuleCount st
            key = RuleKey idx n
            dat = buildRuleData n (newSM key) m (_machPhaseBuf st) (_machLogger st)
            mp  = M.insert key dat $ _machRuleData st
            st' = st { _machRuleData  = mp
                     , _machRuleCount = idx + 1
                     }
        in go st' $ view $ k ()
    go st (Init m :>>= k) =
        let buf  = _machPhaseBuf st
            dat  = buildRuleData "init" (newSM initRuleKey) m buf (_machLogger st)
            typs = initRuleTypeMap dat
            ir   = InitRule dat typs
            st'  = st { _machInitRule = Just ir }
        in go st' $ view $ k ()
    go st (SetSetting Logger  action :>>= k) =
        let st' = st { _machLogger = Just action }
        in go st' $ view $ k ()
    go st (SetSetting RuleFinalizer action :>>= k) =
        let st' = st { _machRuleFin = Just action }
        in go st' $ view $ k ()
    go st (SetSetting PhaseBuffer buf :>>= k ) =
        let st' = st { _machPhaseBuf = buf }
        in go st' $ view $ k ()
    go st (SetSetting DebugMode b :>>= k) =
        let st' = st { _machDebugMode = b }
        in go st' $ view $ k ()
    go st (SetSetting DefaultHandler f :>>= k) =
        let st' = st { _machDefaultHandler = Just f }
        in go st' $ view $ k ()

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
cepEngine :: (Application app, g ~ GlobalState app)
          => g
          -> Specification app ()
          -> Engine
cepEngine s defs = newEngine $ buildMachine s defs

-- | Executes CEP 'Specification' to the 'Process' monad given initial global
--   state.
execute :: (Application app, g ~ GlobalState app)
          => g -> Specification app () -> Process ()
execute s defs = runItForever $ cepEngine s defs

-- | Set of messages accepted by the 'runItForever' driver.
data AcceptedMsg
    = SubMsg Subscribe
    | Debug RuntimeInfoRequest
    | UnsubMsg Unsubscribe
    | SomeMsg Message
    | SomeSMsg PersistMessage

-- | A CEP 'Engine' driver that run an 'Engine' until the end of the universe.
runItForever :: Engine -> Process ()
runItForever start_eng = do
  let debug_mode = stepForward debugModeSetting start_eng
  p <- liftIO $ getTime Monotonic
  bootstrap debug_mode [] (1 :: Integer) . snd =<< stepForward (timeoutMsg p) start_eng
  where
    bootstrap debug_mode ms 1 eng = do
      (ri, nxt_eng) <- stepForward tick eng
      let init_done = stepForward initRulePassedSetting nxt_eng
      when debug_mode . liftIO $ dumpDebuggingInfo Tick 1 ri
      if init_done
        then do
          when debug_mode $ liftIO $ do
            putStrLn "<~~~~~~~~~~ INIT RULE FINISHED ~~~~~~~~~~>"

          p <- liftIO $ getTime Monotonic
          cruise debug_mode 2 . snd =<< stepForward (timeoutMsg p) nxt_eng
        else bootstrap debug_mode ms 2 nxt_eng
    bootstrap debug_mode ms loop eng = do
      msg <- receiveWait
               [ match (return . SubMsg)
               , match (return . UnsubMsg)
               , match (return . SomeSMsg)
               , matchAny (return . SomeMsg)
               ]
      case msg of
        SubMsg sub -> do
          (_, nxt_eng) <- stepForward (rawSubRequest sub) eng
          bootstrap debug_mode ms (succ loop) nxt_eng
        UnsubMsg unsub -> do
          (_, nxt_eng) <- stepForward (rawUnsubRequest unsub) eng
          bootstrap debug_mode ms (succ loop) nxt_eng
        other -> do
          let m :: Request 'Write (Process (RunInfo, Engine))
              m = case other of
                    SomeMsg x    -> rawIncoming x
                    SomeSMsg x   -> rawPersisted x
                    _            -> error "impossible: runItForever"
              act' = requestAction m
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
                then
                  let lefts = reverse (m:ms)
                  in forwardLeftOvers debug_mode (succ loop) nxt_eng lefts
                else bootstrap debug_mode (m:ms) (succ loop) nxt_eng
    forwardLeftOvers debug_mode loop eng [] = do
      p <- liftIO $ getTime Monotonic
      cruise debug_mode loop . snd =<< stepForward (timeoutMsg p) eng
    forwardLeftOvers debug_mode loop eng (x:xs) = do
      (ri, nxt_eng) <- stepForward x eng
      let act = requestAction x
      when debug_mode . liftIO $ dumpDebuggingInfo act loop ri
      forwardLeftOvers debug_mode (succ loop) nxt_eng xs

    -- Normal execution of the engine
    cruise debug_mode !loop eng
      | stepForward engineIsRunning eng = do
        p <- liftIO $ getTime Monotonic
        eng' <- snd <$> stepForward (timeoutMsg p) eng
        -- if we have any runnable rule we first want to check new incoming
        -- messages (and prioritize technical ones), then run machine.
        mtech <- receiveTimeout 0 tech
        case mtech of
          Nothing -> go eng' =<< receiveTimeout 0 all_events
          Just m  -> go eng' (Just m)
      | otherwise = do
        p <- liftIO $ getTime Monotonic
        (c, eng') <- stepForward (timeoutMsg p) eng
        if c > 0
        then cruise debug_mode loop eng' -- we have runnables.
        else case stepForward engineNextEvent eng of
          Nothing -> do
            liftIO $ traceMarkerIO "cep loop: blocked until next event"
            go eng . Just =<< receiveWait all_events
          Just t  -> do
            p' <- liftIO $ getTime Monotonic
            let tm = (toNanoSecs $ p' `diffTimeSpec` t) `div` 1000
            liftIO . traceMarkerIO $ "cep loop: blocked for " ++ show tm ++ "us"
            mmsg <- receiveTimeout (fromIntegral tm) all_events
            case mmsg of
              Nothing -> do eng'' <- snd <$> stepForward (timeoutMsg p') eng
                            cruise debug_mode loop eng''
              _       -> go eng mmsg
      where
        tech = [ match (return . SubMsg)
               , match (return . Debug)
               , match (return . UnsubMsg)
               ]
        all_events = tech ++ [match (return . SomeSMsg), matchAny (return . SomeMsg)]
        go _inner (Just (Debug (RuntimeInfoRequest pid mem))) = do
          liftIO $ traceMarkerIO "cep loop: runtime info request"
          let info = stepForward (getRuntimeInfo mem) eng
          usend pid info
          cruise debug_mode loop eng
        go inner (Just (SubMsg sub)) = do
          liftIO $ traceMarkerIO "cep loop: subscribe request"
          (_, nxt_eng) <- stepForward (rawSubRequest sub) inner
          cruise debug_mode (succ loop) nxt_eng
        go inner (Just (UnsubMsg sub)) = do
          liftIO $ traceMarkerIO "cep loop: unsubscribe request"
          (_, nxt_eng) <- stepForward (rawUnsubRequest sub) inner
          cruise debug_mode (succ loop) nxt_eng
        go inner (Just other)  = do
          liftIO $ traceMarkerIO "cep loop: incomming message"
          let m :: Request 'Write (Process (RunInfo, Engine))
              m = case other of
                    SomeSMsg x   -> rawPersisted x
                    SomeMsg x    -> rawIncoming x
                    _            -> error "impossible: runItForever" --XXX
          (ri, nxt_eng) <- stepForward m inner
          let act = requestAction m
          when debug_mode . liftIO $ dumpDebuggingInfo act loop ri
          cruise debug_mode loop nxt_eng
        go inner Nothing = do
          liftIO $ traceMarkerIO $ "cep loop=" ++ show loop ++ ": tick"
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
                  case p_buf `merelyEqual` buf of
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

-- | Builds a list of 'TypeInfo' types needed by 'PhaseStep' data
--   contructor.
buildSeqList :: Seq -> Set TypeInfo
buildSeqList Nil = Set.empty
buildSeqList (Cons (prx :: Proxy a) rest) =
    let i = TypeInfo (fingerprint (undefined :: a)) prx
    in Set.insert i $ buildSeqList rest

--  | Builds a list of 'TypeInfo' out types need by 'Phase's.
buildTypeList :: Foldable f => f (Jump (Phase g l)) -> Set TypeInfo
buildTypeList = foldr (go . jumpPhaseCall) Set.empty
  where
    go (ContCall (typ :: PhaseType g l a b) _) is =
        case typ of
          PhaseSeq sq _ -> Set.union (buildSeqList sq) is
          _ ->
            let i = TypeInfo (fingerprint (undefined :: a))
                             (Proxy :: Proxy a)
            in Set.insert i is
    go _ is = is

-- | Executes a rule state machine in order to produce a rule state data
--   structure.
buildRuleData :: Application app
              => String
              -> ( Jump (Phase app l)
                -> String
                -> Map String (Jump (Phase app l))
                -> Buffer
                -> l
                -> Maybe (SMLogger app l)
                -> SM app)
              -> RuleM app l (Started app l)
              -> Buffer
              -> Maybe (Log.Event (LogType app) -> GlobalState app -> Process ())
              -> RuleData app
buildRuleData name mk rls buf logFn = go M.empty Set.empty initLogger $ view rls
  where
    initLogger = (\l -> SMLogger l Nothing) <$> logFn
    go ps tpes logger (Return (StartingPhase l p)) =
        RuleData
        { _ruleDataName = name
        , _ruleStack    = mk p name ps buf l logger
        , _ruleTypes    = Set.union tpes $ buildTypeList ps
        }
    go ps tpes logger (Start ph l :>>= k) =
        let old = ps M.! jumpPhaseHandle ph
            jmp = jumpBaseOn ph old
        in go ps tpes logger $ view $ k (StartingPhase l jmp)
    go ps tpes logger (NewHandle n :>>= k) =
        let jmp    = normalJump $ Phase n (DirectCall $ return ())
            handle = PhaseHandle n
            ps'    = M.insert n jmp ps
        in go ps' tpes logger $ view $ k $ normalJump handle
    go ps tpes logger (SetPhase jmp call :>>= k) =
        let _F p    = p { _phCall = call }
            nxt_jmp = fmap _F $ jumpBaseOn jmp (ps M.! jumpPhaseHandle jmp)
            ps'     = M.insert (jumpPhaseHandle jmp) nxt_jmp ps
        in go ps' tpes logger $ view $ k ()
    go ps tpes logger (Wants (prx :: Proxy a) :>>= k) =
        let tok = Token :: Token a
            tpe = TypeInfo (fingerprint (undefined :: a)) prx
        in go ps (Set.insert tpe tpes) logger $ view $ k tok
    go ps tpes logger (SetRuleSetting rs :>>= k) = case rs of
      LocalStateLogger l ->
        go ps tpes ((\sml -> sml{sml_state_logger = Just l}) <$> logger) $ view $ k ()

-- | Subscribes for a specific type of event. Every time that event occures,
--   this 'Process' will receive a 'Published a' message.
subscribe :: forall a proxy. Serializable a
          => ProcessId
          -> proxy a
          -> Process ()
subscribe pid proxy = getSelfPid >>= subscribeThem pid proxy

-- | Subscribe external process to notifications.
subscribeThem :: forall a proxy . Serializable a
              => ProcessId
              -> proxy a
              -> ProcessId
              -> Process ()
subscribeThem pid _ them = rawSubscribeThem pid (fingerprint (undefined :: a)) them

-- | Subscribe external proces to notifications by using event 'Fingerprint'
-- explicitly
rawSubscribeThem :: ProcessId -> Fingerprint -> ProcessId -> Process ()
rawSubscribeThem pid key them = usend pid (Subscribe fgBs them) where
  fgBs = encodeFingerprint key

-- | Unsubscribe process for a specific type of event.
-- Event is asynchronous, so Process may receive 'Published a' after this
-- message.
unsubscribe :: forall a proxy . Serializable a
            => ProcessId
            -> proxy a
            -> Process ()
unsubscribe pid proxy = getSelfPid >>= unsubscribeThem pid proxy

-- | Unsubscribe external process to notifications. (See 'unsubscribe' for
-- details).
unsubscribeThem :: forall a proxy . Serializable a
               => ProcessId
               -> proxy a
               -> ProcessId
               -> Process ()
unsubscribeThem pid _ them = rawUnsubscribeThem pid (fingerprint (undefined :: a)) them


-- | Unsubscribe external proces to notifications by using event 'Fingerprint'
-- explicitly. See 'unsubscribe' for details.
rawUnsubscribeThem :: ProcessId -> Fingerprint -> ProcessId -> Process ()
rawUnsubscribeThem pid key them = usend pid (Unsubscribe fgBs them) where
  fgBs = encodeFingerprint key
