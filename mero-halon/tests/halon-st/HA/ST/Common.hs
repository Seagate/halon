{-# LANGUAGE RecordWildCards #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Common helpers/structures used throughout halon-st
module HA.ST.Common where

import Control.Distributed.Process
import HA.RecoveryCoordinator.Actions.Core (LoopState)
import Network.CEP (Definitions)

data STArgs = STArgs { _sta_test :: HASTTest
                     , _sta_listen :: String
                     , _sta_trackers :: [String]
                     , _sta_eq_timeout :: Int }
  deriving (Show)

data TestArgs = TestArgs { _ta_eq_nids :: [NodeId]
                         , _ta_eq_pid :: ProcessId
                         -- ^ EQ 'ProcessId' at start of test
                         , _ta_rc_pid :: ProcessId
                         -- ^ RC 'ProcessId' at start of test
                         }
  deriving (Show, Eq, Ord)

data HASTTest = HASTTest
  { _st_name :: String
    -- ^ ST name
  , _st_rules :: [Definitions LoopState ()]
    -- ^ Any unique rules that this test relies on. That is, the rules
    -- here should only be used by this test. If you want to re-use a
    -- rule throughout multiple tests, add it directly to
    -- 'HA.ST.Rules.sharedRules'.
  , _st_action :: TestArgs -> Process ()
    -- ^ Test runner that can fail with error
    -- message
  }

instance Show HASTTest where
  show = _st_name
