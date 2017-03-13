-- |
-- Module    : HA.Services.Mero.RC
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Re-exports functionality from "HA.Services.Mero.RC" family of modules.
module HA.Services.Mero.RC
  ( Actions.notifyMeroAsync
  , Actions.mkStateDiff
  , Actions.meroChannel
  , Rules.rules
  , Resources.__remoteTable
  , Resources.__resourcesTable
  ) where

import qualified HA.Services.Mero.RC.Actions as Actions
import qualified HA.Services.Mero.RC.Rules as Rules
import qualified HA.Services.Mero.RC.Resources as Resources
