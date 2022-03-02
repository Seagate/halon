-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
-- Public execution information.
module Network.CEP.Execution where

import Network.CEP.Buffer
import Network.CEP.Types

-- | Possible 'SM' states.
data SMState
      = SMRunning
      -- ^ 'SM' continues it's run and could be executed.
      | SMFinished
      -- ^ 'SM' finished evaluation, and returned a fresh SM.
      | SMSuspended
      -- ^ 'SM' could not do a step forward until a new message will be fed.
      | SMStopped
      -- ^ 'SM' call 'stop' and should be removed from the execution
      deriving Show

-- | Result of SM step
data SMResult = SMResult
        { smId          :: !SMId              -- ^ State machine ID
        , smResultState :: !SMState           -- ^ State machine state after a step.
        , smResultInfo  :: [ExecutionInfo]    -- ^ Information about phases that were run.
        } deriving Show

data RuleName = InitRuleName | RuleName String deriving Show

data RuleInfo =
    RuleInfo
    { ruleName       :: RuleName
    , ruleResults    :: [(SMState, [ExecutionInfo])]
    } deriving Show

data RunResult
    = RulesBeenTriggered [RuleInfo]
    | MsgIgnored
    deriving Show

data RunInfo =
    RunInfo
    { runTotalProcessedMsgs :: !Int
    , runResult             :: !RunResult
    } deriving Show

data StackPhaseInfo
    = StackSinglePhase String
    | StackSwitchPhase String String [String]
    deriving Show

data StackResult = EmptyStack | NeedMore deriving Show

stackPhaseInfoPhaseName :: StackPhaseInfo -> String
stackPhaseInfoPhaseName (StackSinglePhase n)     = n
stackPhaseInfoPhaseName (StackSwitchPhase _ n _) = n

-- | Reason why 'Network.CEP.SM' failed.
data ExecutionFail
      = SuspendExe  -- ^ 'Network.CEP.SM' suspended.
      | StopExe     -- ^ 'Network.CEP.SM' was stopped.
      deriving Show

data ExecutionReport =
    ExecutionReport
    { exeSpawnSMs :: !Int
    , exeTermSMs  :: !Int
    , exeInfos    :: ![ExecutionInfo]
    } deriving Show

data ExecutionInfo
    = SuccessExe
      { exeInfoPhase   :: !String
      , exeInfoPrevBuf :: !Buffer
      , exeInfoBuf     :: !Buffer
      }
    | FailExe
      { exeInfoTarget :: !String
      , exeInfoFail   :: !ExecutionFail
      , exeInfoBuf    :: !Buffer
      }
    deriving Show
