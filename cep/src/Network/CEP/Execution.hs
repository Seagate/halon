-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
-- Public execution information.
module Network.CEP.Execution where

import Network.CEP.Buffer

data RuleName = InitRuleName | RuleName String deriving Show

data RuleInfo =
    RuleInfo
    { ruleInfoName   :: !RuleName
    , ruleStack      :: !StackResult
    , ruleInfoReport :: !ExecutionReport
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

data ExecutionFail = SuspendExe deriving Show

data ExecutionReport =
    ExecutionReport
    { exeSpawnSMs :: !Int
    , exeTermSMs  :: !Int
    , exeInfos    :: ![ExecutionInfo]
    } deriving Show

data ExecutionInfo
    = SuccessExe
      { exeInfoPhase   :: !StackPhaseInfo
      , exeInfoPrevBuf :: !Buffer
      , exeInfoBuf     :: !Buffer
      }
    | FailExe
      { exeInfoTarget :: !String
      , exeInfoFail   :: !ExecutionFail
      , exeInfoBuf    :: !Buffer
      }
    deriving Show