{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Dealing with configurable values throughout the halon rules.
module HA.Resources.HalonVars
  ( HalonVars(..)
  , module HA.Resources.HalonVars
  ) where

import           Data.Binary (Binary)
import           Data.Hashable
import           Data.Typeable
import           GHC.Generics (Generic)

import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import           HA.Resources.Castor (HalonVars(..))
import           HA.SafeCopy
import           Network.CEP

-- | Default value for 'HalonVars'
defaultHalonVars :: HalonVars
defaultHalonVars = HalonVars
  { _hv_recovery_expiry_seconds = 300
  , _hv_recovery_max_retries = (-5)
  , _hv_keepalive_frequency = 30
  , _hv_keepalive_timeout = 115
  , _hv_drive_reset_max_retries = 3
  , _hv_process_configure_timeout = 300
  , _hv_process_start_cmd_timeout = 300
  , _hv_process_start_timeout = 180
  , _hv_process_stop_timeout = 600
  , _hv_process_max_start_attempts = 5
  , _hv_process_restart_retry_interval = 5
  , _hv_mero_kernel_start_timeout = 300
  , _hv_clients_start_timeout = 600
  , _hv_node_stop_barrier_timeout = 600
  , _hv_drive_insertion_timeout = 10
  , _hv_drive_removal_timeout = 60
  , _hv_drive_unpowered_timeout = 300
  , _hv_drive_transient_timeout = 300
  , _hv_expander_node_up_timeout = 460
  , _hv_expander_sspl_ack_timeout = 180
  , _hv_monitoring_angel_delay = 2
  , _hv_mero_workers_allowed = True
  , _hv_disable_smart_checks = False
  , _hv_service_stop_timeout = 30
  , _hv_expander_reset_threshold = 8
  , _hv_expander_reset_reset_timeout = 300
  , _hv_notification_timeout = 115
  , _hv_notification_aggr_delay = 5000
  , _hv_notification_aggr_max_delay = 20000
  , _hv_failed_notification_fails_process = True
  , _hv_sns_operation_status_attempts = 5
  , _hv_sns_operation_retry_attempts = 10
  }

-- | Get 'HalonVars' from RG
getHalonVars :: PhaseM RC l HalonVars
getHalonVars =
    maybe defaultHalonVars id . G.connectedTo Cluster Has <$>
    getGraph

-- | Set a new 'HalonVars' in RG.
setHalonVars :: HalonVars -> PhaseM RC l ()
setHalonVars = modifyGraph . G.connect Cluster Has

-- | Change existing 'HalonVars' in RG.
modifyHalonVars :: (HalonVars -> HalonVars) -> PhaseM RC l ()
modifyHalonVars f = f <$> getHalonVars >>= setHalonVars

-- | Extract a value from 'HalonVars' in RG.
getHalonVar :: (HalonVars -> a) -> PhaseM RC l a
getHalonVar f = f <$> getHalonVars

-- | Set the 'HalonVars' in RG to the variables specified in this
-- message.
newtype SetHalonVars = SetHalonVars HalonVars
  deriving (Show, Eq, Generic, Typeable)
instance Hashable SetHalonVars
deriveSafeCopy 0 'base ''SetHalonVars

-- | 'SetHalonVars' has finished and the 'HalonVars' in this message
-- were set.
newtype HalonVarsUpdated = HalonVarsUpdated HalonVars
  deriving (Show, Eq, Generic, Typeable)
instance Binary HalonVarsUpdated
instance Hashable HalonVarsUpdated
