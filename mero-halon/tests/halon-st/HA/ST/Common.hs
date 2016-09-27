{-# LANGUAGE RecordWildCards #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Common helpers/structures used throughout halon-st
module HA.ST.Common where

import Control.Distributed.Process

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

data HASTTest = HASTTest { _st_name :: String
                           -- ^ ST name
                         , _st_action :: TestArgs -> IO (Maybe String)
                           -- ^ Test runner that can fail with error
                           -- message
                         }

instance Show HASTTest where
  show = _st_name
