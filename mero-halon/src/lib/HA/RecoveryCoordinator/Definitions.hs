{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Recovery coordinator definitions
module HA.RecoveryCoordinator.Definitions
    ( HA.RecoveryCoordinator.Definitions.__remoteTable
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

import HA.Multimap
import HA.RecoveryCoordinator.CEP
import HA.RecoveryCoordinator.Mero

recoveryCoordinator :: [NodeId]
                    -> ProcessId
                    -> StoreChan
                    -> Process ()
recoveryCoordinator eqs eq mm =
    makeRecoveryCoordinator mm eq $ rcRules (IgnitionArguments eqs) []

recoveryCoordinatorEx :: () -> [Definitions RC ()]
                      -> [NodeId]
                      -> ProcessId
                      -> StoreChan
                      -> Process ()
recoveryCoordinatorEx _ rules eqs eq mm = do
  makeRecoveryCoordinator mm eq $ rcRules (IgnitionArguments eqs) rules

remotable [ 'recoveryCoordinator, 'recoveryCoordinatorEx ]
