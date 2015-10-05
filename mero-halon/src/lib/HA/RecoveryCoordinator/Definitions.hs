{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Recovery coordinator definitions
module HA.RecoveryCoordinator.Definitions
    ( HA.RecoveryCoordinator.Definitions.__remoteTable
    , ignitionArguments
    , ignitionArguments__sdict
    , ignitionArguments__static
    , recoveryCoordinator__sdict
    , recoveryCoordinator__static
    , recoveryCoordinator
    , recoveryCoordinatorEx__sdict
    , recoveryCoordinatorEx__static
    , recoveryCoordinatorEx
    ) where

import Network.CEP (Definitions)
import Control.Distributed.Process
import Control.Distributed.Process.Closure

import HA.RecoveryCoordinator.CEP
import HA.RecoveryCoordinator.Mero

ignitionArguments :: [NodeId] -> IgnitionArguments
ignitionArguments = IgnitionArguments

recoveryCoordinator :: IgnitionArguments
                    -> ProcessId
                    -> ProcessId
                    -> Process ()
recoveryCoordinator argv eq mm =
    makeRecoveryCoordinator mm $ rcRules argv eq []

recoveryCoordinatorEx :: IgnitionArguments
                      -> (Static [Definitions LoopState ()])
                      -> ProcessId
                      -> ProcessId
                      -> Process ()
recoveryCoordinatorEx argv cdefs eq mm = do
  rules <- unStatic cdefs
  makeRecoveryCoordinator mm $ rcRules argv eq rules

remotable [ 'ignitionArguments, 'recoveryCoordinator, 'recoveryCoordinatorEx ]
