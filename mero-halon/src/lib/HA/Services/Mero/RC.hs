-- |
-- Module    : HA.Services.Mero.RC
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Re-exports functionality from "HA.Services.Mero.RC" family of modules.
module HA.Services.Mero.RC
  ( Actions.notifyMeroAsync
  , Actions.mkStateDiff
  , Rules.rules
  , Resources.__remoteTable
  , Resources.__resourcesTable
  ) where

import qualified HA.Services.Mero.RC.Actions as Actions
import qualified HA.Services.Mero.RC.Rules as Rules
import qualified HA.Services.Mero.RC.Resources as Resources
