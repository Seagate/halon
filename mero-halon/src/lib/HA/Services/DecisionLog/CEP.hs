{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog.CEP where

import Control.Distributed.Process
import Network.CEP

import HA.Services.DecisionLog.Types

decisionLogRules :: WriteLogs -> Definitions s ()
decisionLogRules wl =
    defineSimple "entries-submitted" $ \logs -> liftProcess $ do
      writeLogs wl logs
      say "entries submitted"
