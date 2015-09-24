{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog.CEP where

import Network.CEP

import HA.Services.DecisionLog.Types

decisionLogRules :: WriteLogs -> Definitions s ()
decisionLogRules wl =
    defineSimple "entries-submitted" $ \logs ->
      liftProcess $ writeLogs wl logs
