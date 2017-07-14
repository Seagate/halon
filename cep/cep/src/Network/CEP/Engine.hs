{-# LANGUAGE CPP             #-}
{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE GADTs           #-}
{-# LANGUAGE KindSignatures  #-}
{-# LANGUAGE Rank2Types      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections   #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns     #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
module Network.CEP.Engine where

import Data.Traversable (for)
import Data.Foldable (for_)
import Data.Either (partitionEithers)
import Data.Binary (Binary)
import Data.Typeable (Typeable)

import           Control.Distributed.Process hiding (bracket_)
import           Control.Distributed.Process.Internal.Types
import           Control.Distributed.Process.Serializable
import qualified Control.Monad.Trans.State.Strict as State
import           Control.Monad.Trans
import           Control.Monad.Catch (bracket_)
import           Control.Exception (assert) -- XXX DELETEME
import qualified Data.MultiMap       as MM
import qualified Data.Map.Strict     as M
import qualified Data.Set            as Set
import           Data.Traversable (mapAccumL)
import           Data.UUID (UUID)
import qualified Data.IntPSQ as PSQ
import           Data.ByteString.Lazy (ByteString)
import           Control.Lens
import           Debug.Trace

import GHC.Generics
#ifdef VERSION_ghc_datasize
import GHC.DataSize (recursiveSize)
#endif
import System.IO.Unsafe (unsafePerformIO)
import System.Clock

import           Data.PersistMessage
import           Network.CEP.Buffer
import           Network.CEP.Execution
import qualified Network.CEP.Log as Log
import           Network.CEP.SM
import           Network.CEP.Types

-- XXX DELETEME <<<<<<<
showXXX :: String -> Integer -> String -> String
showXXX func line rest = "XXX [" ++ func ++ ":" ++ show line ++ "]" ++ rest'
  where
    rest' = if null rest then "" else ' ':rest
-- XXX DELETEME >>>>>>>

data Input
    = NoMessage
    | GotMessage TypeInfo Message

-- | Rule state data structure.
data RuleData app = RuleData
    { _ruleDataName :: !String
      -- ^ Rule name.
    , _ruleStack :: !(SM app)
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

data Select a = GetSetting (EngineSetting a)
                -- ^ Get CEP 'Engine' internal setting.
              | GetRuntimeInfo Bool (RuntimeInfoQuery a)
                -- ^ Get runtime information

data Action a where
    Tick           :: Action RunInfo
    Incoming       :: Message -> Action RunInfo
    IncomingXXX    :: (UUID, Message) -> Action RunInfo
    Unpersist      :: PersistMessage -> Action RunInfo
    NewSub         :: Subscribe -> Action ()
    Unsub          :: Unsubscribe -> Action ()
    TimeoutArrived :: TimeSpec -> Action Int
    -- Wake up all threads that reached timeout, return
    -- number of threads awaken.

data EngineSetting a where
    EngineDebugMode      :: EngineSetting Bool
    EngineInitRulePassed :: EngineSetting Bool
    EngineIsRunning      :: EngineSetting Bool
    EngineNextEvent      :: EngineSetting (Maybe TimeSpec)

data RuntimeInfoQuery a where
    RuntimeInfoTotal :: RuntimeInfoQuery RuntimeInfo

data MemoryInfo = MemoryInfo
    { minfoTotalSize :: Int
    , minfoSMSize :: Int
    , minfoStateSize :: Int
    }
  deriving (Show, Generic, Typeable)

instance Binary MemoryInfo

data RuntimeInfo = RuntimeInfo
      { infoTotalSM :: Int
      , infoRunningSM :: Int
      , infoSuspendedSM :: Int
      , infoMemory :: Maybe MemoryInfo
      , infoSMs :: M.Map String Int
      }
  deriving (Show, Generic, Typeable)

instance Binary RuntimeInfo

initRulePassedSetting :: Request 'Read Bool
initRulePassedSetting = Query $ GetSetting EngineInitRulePassed

debugModeSetting :: Request 'Read Bool
debugModeSetting = Query $ GetSetting EngineDebugMode

engineIsRunning :: Request 'Read Bool
engineIsRunning = Query $ GetSetting EngineIsRunning

engineNextEvent :: Request 'Read (Maybe TimeSpec)
engineNextEvent = Query $ GetSetting EngineNextEvent

getRuntimeInfo :: Bool -- ^ Include memory info?
               -> Request 'Read RuntimeInfo
getRuntimeInfo mem = Query $ GetRuntimeInfo mem RuntimeInfoTotal

tick :: Request 'Write (Process (RunInfo, Engine))
tick = Run Tick

rawSubRequest :: Subscribe -> Request 'Write (Process ((), Engine))
rawSubRequest = Run . NewSub

rawUnsubRequest :: Unsubscribe -> Request 'Write (Process ((), Engine))
rawUnsubRequest = Run . Unsub

rawIncoming :: Message -> Request 'Write (Process (RunInfo, Engine))
rawIncoming = Run . Incoming

rawIncomingXXX :: (UUID, Message) -> Request 'Write (Process (RunInfo, Engine))
rawIncomingXXX = Run . IncomingXXX

rawPersisted :: PersistMessage -> Request 'Write (Process (RunInfo, Engine))
rawPersisted = Run . Unpersist

timeoutMsg :: TimeSpec -> Request 'Write (Process (Int, Engine))
timeoutMsg = Run . TimeoutArrived

requestAction :: Request 'Write (Process (a, Engine)) -> Action a
requestAction (Run a) = a

-- CEP Engine finit state machine represented as a Mealy machine.
newtype Engine = Engine { _unE :: forall a m. Request m a -> a }

stepForward :: Request m a -> Engine -> a
stepForward i (Engine k) = k i

-- | Holds init rule state.
data InitRule app where
    InitRule :: Application app => {
        _initRuleData :: !(RuleData app)
        -- ^ Init rule state.
      , _initRuleTypes :: !(M.Map Fingerprint TypeInfo)
        -- ^ Keep track of type of messages handled by the init rule.
      } -> InitRule app

-- | Information required to control SM
data SMData s = SMData !SMId !RuleKey !(RuleData s)

-- | Main CEP engine state structure.
data Machine app where
    Machine :: Application app => {
        _machRuleData :: !(M.Map RuleKey (RuleData app))
        -- ^ Rules defined by the users.
      , _machSubs :: !Subscribers
        -- ^ Subscribers interested in events issued by this CEP engine.
      , _machLogger :: !(Maybe (Log.Event (LogType app) -> GlobalState app -> Process ()))
        -- ^ Logger callback.
      , _machRuleFin :: !(Maybe ((GlobalState app) -> Process (GlobalState app)))
        -- ^ Callback used when app rule has completed.
      , _machRuleCount :: !Int
        -- ^ It will get you the number of rules that CEP engine handles. but
        --   it's use to order rule by order in appearence when generating
        --   'RuleKey'.
      , _machPhaseBuf :: !Buffer
        -- ^ Default buffer when forking a new 'Phase' state machine.
      , _machTypeMap :: !(MM.MultiMap Fingerprint (RuleKey, TypeInfo))
        -- ^ Keep track of every rule interested in a certain message type.
        --   It also keeps type information that helpful for deserializing.
      , _machState :: !(GlobalState app)
        -- ^ CEP engine global state.
      , _machDebugMode :: !Bool
        -- ^ Set the CEP engine in debug mode, dumping more internal log to the
        --   the terminal.
      , _machInitRule :: !(Maybe (InitRule app))
        -- ^ Rule to run at 'InitStep' step.
      , _machTotalProcMsgs :: !Int
      , _machInitRulePassed :: !Bool
        -- ^ Indicates the if the init rule has been executed already.
      , _machRunningSM :: [SMData app]
        -- ^ List of SM that is in a runnable state
      , _machSuspendedSM :: [SMData app]
        -- ^ List of SM that are in suspended state
      , _machDefaultHandler :: !(Maybe (UUID -> StablePrint -> ByteString -> (GlobalState app) -> Process ()))
        -- ^ Handler for 'PersistMessages' of an unknown type.
        -- Raw messages of unknown type are silently discarded.
      , _machMaxThreadId :: !SMId
        -- ^ Maximum SMId
      , _machSFingerprint :: !(M.Map StablePrint Fingerprint)
        -- ^ List of the stable fingeprints
      , _machTimestamp :: !TimeSpec
        -- ^ Machine current timestamp
      , _machEvents :: !(PSQ.IntPSQ TimeSpec RuleKey)
      } -> Machine app

makeLensesFor [("_machMaxThreadId","machineMaxThreadId")
              ,("_machState", "machineState")]
              ''Machine

engineState :: (Application app, g ~ GlobalState app)
            => Lens' (Machine app) (EngineState g)
engineState f m =
      (\(EngineState t' x z s') -> m{_machMaxThreadId=t',_machState=s',_machTimestamp=x, _machEvents=z})
  <$> f (EngineState (_machMaxThreadId m) (_machTimestamp m) (_machEvents m) (_machState m))

-- | Creates CEP engine state with default properties.
emptyMachine :: Application a => GlobalState a -> Machine a
emptyMachine s =
    Machine
    { _machRuleData       = M.empty
    , _machSubs           = M.empty
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
    , _machMaxThreadId    = 0
    , _machSFingerprint   = M.empty
    , _machTimestamp      = 0 --  bad
    , _machEvents         = PSQ.empty
    }

newEngine :: Application app => Machine app -> Engine
newEngine st = Engine $ cepInit st

cepInit :: Application app => Machine app -> Request m a -> a
cepInit st i =
    case _machInitRule st' of
      Nothing -> do
          let nxt_st = st' { _machInitRulePassed = True }
          cepCruise nxt_st i
      Just ir -> cepInitRule ir st' i
  where
    st' = st{_machRunningSM = sms
            ,_machMaxThreadId = SMId (m + fromIntegral (length sms))
            }
    (SMId m) = _machMaxThreadId st
    sms = zipWith (\idx (rk,d) -> SMData (SMId idx) rk d)
                  [m..]
                  (M.assocs $ _machRuleData st)

-- | Process subscription request.
cepSubRequest :: Machine app -> Subscribe -> Machine app
cepSubRequest st@Machine{..} (Subscribe tpe pid) = nxt_st
  where
    key      = decodeFingerprint tpe
    nxt_subs = M.alter (\v -> case v of
                  Nothing -> Just $ Set.singleton pid
                  Just xs -> Just $ Set.insert pid xs)
                  key _machSubs
    nxt_st   = st { _machSubs = nxt_subs }

-- | Process unsubscription request.
cepUnsubRequest :: Machine app -> Unsubscribe -> Machine app
cepUnsubRequest st@Machine{..} (Unsubscribe tpe pid) = nxt_st
  where
    key      = decodeFingerprint tpe
    nxt_subs = M.alter (\v -> case v of
                   Nothing -> Nothing
                   Just xs -> case Set.delete pid xs of
                                xs' | Set.null xs' -> Nothing
                                    | otherwise -> Just xs'
                                ) key _machSubs
    nxt_st   = st { _machSubs = nxt_subs }

defaultHandler :: Machine app
               -> (forall b n. Machine app -> Request n b -> b)
               -> Request m a
               -> a
defaultHandler st next (Run (NewSub sub)) =
    return ((), Engine $ next $ cepSubRequest st sub)
defaultHandler st next (Run (Unsub sub)) =
    return ((), Engine $ next $ cepUnsubRequest st sub)
defaultHandler st next (Run Tick) =
    return (RunInfo (_machTotalProcMsgs st) MsgIgnored, Engine $ next st)
defaultHandler _ _ (Run (IncomingXXX _)) = error "Impossible happened!"
defaultHandler st next (Run (Incoming _)) = do
    return (RunInfo (_machTotalProcMsgs st) MsgIgnored, Engine $ next st)
defaultHandler st next (Run (TimeoutArrived t)) =
    return (0, Engine $ next st{_machTimestamp=t})
defaultHandler _ _ (Run (Unpersist (PersistMessage uuid _ _))) | trace (showXXX "defaultHandler" __LINE__ $ "PersistMessage " ++ show uuid) False = undefined
defaultHandler st next (Run (Unpersist (PersistMessage uuid sfp payload))) = do
  case M.lookup sfp (_machSFingerprint st) of
    Nothing -> do
      traceM $ showXXX "defaultHandler" __LINE__ $ "PersistMessage " ++ show uuid ++ "; sftp=" ++ show sfp ++ " not found ==> MsgIgnored"
      for_ (_machDefaultHandler st) $ \handler ->
        handler uuid sfp payload (_machState st)
      return (RunInfo 0 MsgIgnored, Engine $ next st)
    Just fp -> do
      traceM $ showXXX "defaultHandler" __LINE__ $ "PersistMessage " ++ show uuid ++ "; " ++ show sfp ++ " -> " ++ show fp
      liftIO $ traceMarkerIO $ "cep: smessage: " ++ show sfp ++ " -> " ++ show fp
      next st $ rawIncomingXXX (uuid, EncodedMessage fp payload)
      -- next st $ rawIncoming $ EncodedMessage fp payload
defaultHandler st _ (Query (GetSetting s)) =
    case s of
      EngineDebugMode      -> _machDebugMode st
      EngineInitRulePassed -> _machInitRulePassed st
      EngineIsRunning      -> not (null (_machRunningSM st))
      EngineNextEvent      -> (\(_,x,_) -> x) <$> PSQ.findMin (_machEvents st)
defaultHandler st _ (Query (GetRuntimeInfo mem RuntimeInfoTotal)) =
    let running = _machRunningSM st
        suspended = _machSuspendedSM st
        mRunning = M.fromListWith (+)
                 $ map (\(SMData _ k _) -> (_ruleKeyName k, 1)) running
        mSuspended = M.fromListWith (+)
                   $ map (\(SMData _ k _) -> (_ruleKeyName k, 1)) suspended
        nRunning = length running
        nSuspended = length suspended
#ifdef VERSION_ghc_datasize
        minfo = if mem
                then Just $ MemoryInfo
                  { minfoTotalSize = unsafePerformIO $ recursiveSize st
                  , minfoSMSize = unsafePerformIO (recursiveSize running)
                                + unsafePerformIO (recursiveSize suspended)
                  , minfoStateSize
                      = unsafePerformIO (recursiveSize (_machState st))
                  }
                else Nothing
#else
        minfo = Nothing
#endif
    in RuntimeInfo
        { infoTotalSM = nRunning + nSuspended
        , infoMemory = minfo
        , infoRunningSM  = nRunning
        , infoSuspendedSM = nSuspended
        , infoSMs = M.unionWith (+) mRunning mSuspended
        }

interestingMsg :: (Fingerprint -> Bool) -> Message -> Bool
interestingMsg k msg = k $ messageFingerprint msg

foreach :: Functor f => f a -> (a -> b) -> f b
foreach xs f = fmap f xs

cepInitRule :: Application app => InitRule app -> Machine app -> Request m a -> a
cepInitRule ir@(InitRule rd typs) st@Machine{..} req@(Run i) = do
    case i of
      Tick -> go NoMessage _machTotalProcMsgs
      Incoming m@((`M.lookup` typs) . messageFingerprint -> Just tpe) ->
          let msg       = GotMessage tpe m
              msg_count = _machTotalProcMsgs + 1 in
          go msg msg_count
      Incoming _ -> defaultHandler st (cepInitRule ir) req
      -- XXX DELETEME <<<<<<<
      Unpersist (PersistMessage uuid _ _) -> do
        traceM $ showXXX "cepInitRule" __LINE__ $ "PersistMessage " ++ show uuid
        defaultHandler st (cepInitRule ir) req
      -- XXX DELETEME >>>>>>>
      _          -> defaultHandler st (cepInitRule ir) req
  where
    go (GotMessage ty m) msg_count = do
      let stack' = runSM (_ruleStack rd) (SMMessage ty m)
          rinfo = RunInfo 0 (RulesBeenTriggered [])
      return (rinfo, Engine $ cepInitRule (InitRule rd{_ruleStack=stack'} typs)
                                          st{ _machTotalProcMsgs = msg_count })
    go NoMessage msg_count = do
      let exe = SMExecute _machSubs
      -- We do not allow fork inside init rule, this may be ok or not
      -- depending on a usecase, but allowing fork will make implementation
      -- much harder and do not worth it, unless we have a concrete example.
      ([(SMResult _ out infos, nxt_stk)], (EngineState mti _ e g)) <-
          State.runStateT (runSM (_ruleStack rd) exe)
                          (EngineState _machMaxThreadId _machTimestamp _machEvents _machState)
      let new_rd = rd { _ruleStack = nxt_stk }
          nxt_st = st { _machState = g, _machEvents = e }
          rinfo = RuleInfo InitRuleName [(out, infos)]
          info  = RunInfo msg_count (RulesBeenTriggered [rinfo])
      case out of
        SMFinished -> do
          let final_st = nxt_st { _machInitRulePassed = True, _machMaxThreadId = mti}
          return (info, Engine $ cepCruise final_st)
        SMRunning -> cepInitRule (InitRule new_rd typs) nxt_st (Run Tick)
        _ -> return (info, Engine $ cepInitRule (InitRule new_rd typs) nxt_st)
cepInitRule ir st req = defaultHandler st (cepInitRule ir) req

cepCruise :: Application app => Machine app -> Request m a -> a
cepCruise !st req@(Run t) =
    case t of
      Tick -> do
        -- XXX: currently only runnable SM are started, so if rule has
        --      an effectfull requirements to pass this could be a problem
        --      for the rule.
        (infos, nxt_st) <- State.runStateT executeTick st
        traceM $ showXXX "cepCruise" __LINE__ $ "Tick executed: messages_processed=" ++ show (_machTotalProcMsgs nxt_st) ++ " rules_triggered=" ++ show ((\ri -> (ruleName ri, "[XXX_ruleResults]")) <$> infos)
        let rinfo = RunInfo (_machTotalProcMsgs nxt_st) (RulesBeenTriggered infos)
        return (rinfo, Engine $ cepCruise nxt_st)
      TimeoutArrived ts ->
        let loop !c nst = case PSQ.findMin (_machEvents nst) of
              Nothing -> return (c, Engine $ cepCruise nst{_machEvents=PSQ.deleteMin (_machEvents nst)})
              Just (_,t',key)
                | ts < t' ->  return (c, Engine $ cepCruise nst)
                | otherwise ->
                   let xs     = filter (\(SMData _ k _) -> key == k) $ _machSuspendedSM nst
                       nxt_su = filter (\(SMData _ k _) -> key /= k) $ _machSuspendedSM nst
                       prev   = _machRunningSM nst
                       nxt_st = st { _machRunningSM   = prev ++ xs
                                   , _machSuspendedSM = nxt_su
                                   , _machEvents = PSQ.deleteMin (_machEvents nst)}
                   in loop (c+1) nxt_st
        in loop 0 st{_machTimestamp = ts}
      IncomingXXX (uuid, m) -> do
        let isInteresting = interestingMsg (MM.member (_machTypeMap st)) m
            interestedRules =
              fst <$> messageFingerprint m `MM.lookup` _machTypeMap st
        assert (isInteresting == null interestedRules) pure ()
        traceM $ showXXX "cepCruise" __LINE__ $ show uuid
          ++ (if isInteresting
              then " is interesting; interestedRules=" ++ show interestedRules
              else " is NOT interesting")
#if 0 /* XXX */
        cepCruise st $ Run (Incoming m)
#else
        traceM $ showXXX "cepCruise" __LINE__ $ show uuid ++ " m :: " ++ (if isEncoded m then "EncodedMessage" else show m)
        traceM $ showXXX "cepCruise" __LINE__ $ show uuid ++ " interested_rules=" ++ show (fst <$> messageFingerprint m `MM.lookup` _machTypeMap st)
        let fpt = messageFingerprint m
            keyInfos = fpt `MM.lookup` _machTypeMap st
        traceM $ showXXX "cepCruise" __LINE__ $ show uuid ++ " fpt=" ++ show fpt ++ " keyInfos=" ++ show (fst <$> keyInfos)
        let smdataXXX (SMData smid rkey rdata) = "smid=" ++ show smid ++ " rkey=" ++ show rkey ++ " rd=" ++ _ruleDataName rdata
            (upd, running') = mapAccumL
              (\u smdata@(SMData idx key rd) ->
                case key `lookup` keyInfos of
                  Just info ->
                    let stack' = runSM (_ruleStack rd) (SMMessage info m)
                    in trace (showXXX "cepCruise" __LINE__ $ show uuid ++ " SM has been run! " ++ smdataXXX smdata) (u+1, SMData idx key rd{_ruleStack=stack'})
                  Nothing -> trace (showXXX "cepCruise" __LINE__ $ show uuid ++ " key not in keyInfos; " ++ smdataXXX smdata) (u, SMData idx key rd)) 0 (_machRunningSM st)
            splitted = foreach (_machSuspendedSM st) $
              \smdata@(SMData idx key rd) ->
                case key `lookup` keyInfos of
                  Just info ->
                    let stack' = runSM (_ruleStack rd) (SMMessage info m)
                    in trace (showXXX "cepCruise" __LINE__ $ show uuid ++ " SM has been run! " ++ smdataXXX smdata) $ Right (SMData idx key rd{_ruleStack=stack'})
                  Nothing -> trace (showXXX "cepCruise" __LINE__ $ show uuid ++ " key not in keyInfos; " ++ smdataXXX smdata) $ Left (SMData idx key rd)
            (susp, running) = partitionEithers splitted
            rinfo = RunInfo (upd + length running)
              $ if upd + length running == 0
                  then MsgIgnored
                  else RulesBeenTriggered []
        liftIO $ traceMarkerIO $ "cep: message: " ++ show fpt
        traceM $ showXXX "cepCruise" __LINE__ $ show uuid ++ " running_SMs_triggered=" ++ show upd ++ " suspended_SMs_triggered=" ++ show (length running)
        return (rinfo, Engine $ cepCruise st{_machRunningSM   = running' ++ running
                                            ,_machSuspendedSM = susp
                                            })
#endif
      -- XXX DELETEME <<<<<<<
      Incoming m | not (interestingMsg (MM.member (_machTypeMap st)) m) -> do
        traceM $ showXXX "cepCruise" __LINE__ "Incoming, but NOT interesting!"
        defaultHandler st cepCruise req
      -- XXX DELETEME >>>>>>>
      Incoming m | interestingMsg (MM.member (_machTypeMap st)) m -> do
        traceM $ showXXX "cepCruise" __LINE__ $ "m :: " ++ (if isEncoded m then "EncodedMessage" else show m)
        traceM $ showXXX "cepCruise" __LINE__ $ "interested_rules=" ++ show (fst <$> messageFingerprint m `MM.lookup` _machTypeMap st)
        let fpt = messageFingerprint m
            keyInfos = fpt `MM.lookup` _machTypeMap st
        traceM $ showXXX "cepCruise" __LINE__ $ "fpt=" ++ show fpt ++ " keyInfos=" ++ show (fst <$> keyInfos)
        let smdataXXX (SMData smid rkey rdata) = "smid=" ++ show smid ++ " rkey=" ++ show rkey ++ " rd=" ++ _ruleDataName rdata
            (upd, running') = mapAccumL
              (\u smdata@(SMData idx key rd) ->
                case key `lookup` keyInfos of
                  Just info ->
                    let stack' = runSM (_ruleStack rd) (SMMessage info m)
                    in trace (showXXX "cepCruise" __LINE__ $ "SM has been run! " ++ smdataXXX smdata) (u+1, SMData idx key rd{_ruleStack=stack'})
                  Nothing -> trace (showXXX "cepCruise" __LINE__ $ "key not in keyInfos; " ++ smdataXXX smdata) (u, SMData idx key rd)) 0 (_machRunningSM st)
            splitted = foreach (_machSuspendedSM st) $
              \smdata@(SMData idx key rd) ->
                case key `lookup` keyInfos of
                  Just info ->
                    let stack' = runSM (_ruleStack rd) (SMMessage info m)
                    in trace (showXXX "cepCruise" __LINE__ $ "SM has been run! " ++ smdataXXX smdata) $ Right (SMData idx key rd{_ruleStack=stack'})
                  Nothing -> trace (showXXX "cepCruise" __LINE__ $ "key not in keyInfos; " ++ smdataXXX smdata) $ Left (SMData idx key rd)
            (susp, running) = partitionEithers splitted
            rinfo = RunInfo (upd + length running)
              $ if upd + length running == 0
                  then MsgIgnored
                  else RulesBeenTriggered []
        liftIO $ traceMarkerIO $ "cep: message: " ++ show fpt
        traceM $ showXXX "cepCruise" __LINE__ $ "running_SMs_triggered=" ++ show upd ++ " suspended_SMs_triggered=" ++ show (length running)
        return (rinfo, Engine $ cepCruise st{_machRunningSM   = running' ++ running
                                            ,_machSuspendedSM = susp
                                            })
      _ -> defaultHandler st cepCruise req
cepCruise st req = defaultHandler st cepCruise req

-- | Execute one step of the Engine.
executeTick :: Application app => State.StateT (Machine app) Process [RuleInfo]
executeTick = do
    running <- bootstrap
    info <- traverse execute running
    sti <- State.get
    g_opt <- for (_machRuleFin sti) $ \k -> lift $ k (_machState sti)
    for_ g_opt $ \g -> State.modify $ \n -> n{_machState=g}
    return info
  where
    bootstrap = do
      st <- State.get
      State.put st{_machRunningSM=[]}
      return (_machRunningSM st)
    execute (SMData smid key (RuleData rn _ _)) | trace (showXXX "executeTick.execute" __LINE__ $ "smid=" ++ show (getSMId smid) ++ " key=" ++ show key ++ " rn=" ++ rn) False = undefined
    execute (SMData smid key sm) =
      bracket_ (do { liftIO $ traceEventIO $ "START cep:engine:execute:" ++ _ruleKeyName key;
               traceM $ showXXX "executeTick.execute" __LINE__ $ "START smid=" ++ show (getSMId smid) ++ " key=" ++ show key })
               (do { liftIO $ traceEventIO $ "STOP cep:engine:execute:" ++ _ruleKeyName key;
               traceM $ showXXX "executeTick.execute" __LINE__ $ "STOP smid=" ++ show (getSMId smid) ++ " key=" ++ show key })
               $ do
      sti <- State.get
      let exe  = SMExecute (_machSubs sti)
      machines <- zoom engineState $ (runSM (_ruleStack sm) exe)
      let addRunning   = foldr (\x y -> mkRunningSM x . y) id machines
          addSuspended = foldr (\x y -> mkSuspendedSM x . y) id machines
          mkRunningSM (SMResult idx SMRunning  _, s) = (mkSM idx s :)
          mkRunningSM (SMResult idx SMFinished _, s) = (mkSM idx s :)
          mkRunningSM _  = id
          mkSuspendedSM (SMResult idx SMSuspended _, s) = (mkSM idx s :)
          mkSuspendedSM _ = id
          mkSM idx nxt_stk = SMData idx key $ sm{_ruleStack=nxt_stk}
      State.modify $ \nxt_st ->
        nxt_st{_machRunningSM = addRunning $ _machRunningSM nxt_st
              ,_machSuspendedSM = addSuspended $ _machSuspendedSM nxt_st
              }
      return $ RuleInfo (RuleName $ _ruleDataName sm)
             $ map ((\(SMResult _ s r) -> (s, r)) . fst) machines
