{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013,2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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

-- | Start a Recovery Coordinator with 'rcRules'.
recoveryCoordinator :: [NodeId] -- ^ EQ nodes
                    -> ProcessId -- ^ Co-located EQ
                    -> StoreChan -- ^ Multimap information
                    -> Process ()
recoveryCoordinator eqs eq mm =
    makeRecoveryCoordinator mm eq $ rcRules (IgnitionArguments eqs) []

-- | As 'recoveryCoordinator' but allows the user to specify extra
-- rules RC should run with.
recoveryCoordinatorEx :: ()
                      -> [Definitions RC ()] -- ^ Extra rules (on top of 'rcRules').
                      -> [NodeId] -- ^ EQ nodes
                      -> ProcessId -- ^ Co-located EQ
                      -> StoreChan -- ^ Multimap information
                      -> Process ()
recoveryCoordinatorEx _ rules eqs eq mm = do
  makeRecoveryCoordinator mm eq $ rcRules (IgnitionArguments eqs) rules

remotable [ 'recoveryCoordinator, 'recoveryCoordinatorEx ]
