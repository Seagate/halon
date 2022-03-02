-- |
-- Module    : HA.Services.Ekg.RC
-- Copryight : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Collection of functions for interacting with EKG service from the
-- RC.
module HA.Services.Ekg.RC
  ( module HA.Services.Ekg
  , runEkgMetricCmd
  ) where

import Control.Distributed.Process
import HA.Services.Ekg
import Network.CEP

-- | Update an EKG metric for the EKG instance on the current node.
--
-- The metric is created if it doesn't already exist. Nothing is done
-- if no EKG service is running on the current node. Example:
--
-- @
-- runEkgMetricCmd ('ModifyGauge' "running_disk_resets" 'GaugeInc')
-- @
runEkgMetricCmd :: MonadProcess m => ModifyMetric -> m ()
runEkgMetricCmd cmd = liftProcess $
  getSelfNode >>= \nid -> runEkgMetricCmdOnNode nid cmd
