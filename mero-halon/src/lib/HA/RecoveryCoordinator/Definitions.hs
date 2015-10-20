{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Recovery coordinator definitions
module HA.RecoveryCoordinator.Definitions
    ( HA.RecoveryCoordinator.Definitions.__remoteTable
    , IgnitionArguments
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

recoveryCoordinatorEx :: () -> [Definitions LoopState ()]
                      -> IgnitionArguments
                      -> ProcessId
                      -> ProcessId
                      -> Process ()
recoveryCoordinatorEx _ rules argv eq mm = do
  makeRecoveryCoordinator mm $ rcRules argv eq rules

remotable [ 'ignitionArguments, 'recoveryCoordinator, 'recoveryCoordinatorEx ]
