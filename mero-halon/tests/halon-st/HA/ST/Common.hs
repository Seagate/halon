{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Common helpers/structures used throughout halon-st
module HA.ST.Common where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Data.Proxy
import HA.RecoveryCoordinator.Actions.Core (LoopState)
import Network.CEP (Definitions)

data STArgs = STArgs { _sta_test :: HASTTest
                     , _sta_listen :: String
                     , _sta_trackers :: [String]
                     , _sta_eq_timeout :: Int }
  deriving (Show)

-- | Arguments passed to ST tests.
data TestArgs = TestArgs { _ta_eq_nids :: [NodeId]
                         , _ta_eq_pid :: ProcessId
                         -- ^ EQ 'ProcessId' at start of test
                         , _ta_rc_pid :: ProcessId
                         -- ^ RC 'ProcessId' at start of test
                         }
  deriving (Show, Eq, Ord)

-- | Wrapper for halon ST test.
data HASTTest = HASTTest
  { _st_name :: String
    -- ^ ST name
  , _st_rules :: [Definitions LoopState ()]
    -- ^ Any unique rules that this test relies on. That is, the rules
    -- here should only be used by this test. If you want to re-use a
    -- rule throughout multiple tests, add it directly to
    -- 'HA.ST.Rules.sharedRules'.
  , _st_action :: TestArgs -> (String -> IO ())-> Process ()
    -- ^ Test runner that can fail with error message. Takes a @step@
    -- function to annonunce progress with to test runner.
  }

instance Show HASTTest where
  show = _st_name

-- | Remove any messages of type @a@ from the process mailbox.
emptyMailbox :: Serializable t => Proxy t -> Process ()
emptyMailbox t@(Proxy :: Proxy t) = expectTimeout 0 >>= \case
  Nothing -> return ()
  Just (_ :: t) -> emptyMailbox t
