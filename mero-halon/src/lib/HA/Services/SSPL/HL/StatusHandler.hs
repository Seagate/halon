-- |
-- Module    : HA.Services.SSPL.HL.StatusHandler
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Handler for 'CommandResponseMessage's.
module HA.Services.SSPL.HL.StatusHandler where

import Control.Distributed.Process
import HA.EventQueue (promulgate)
import SSPL.Bindings

import Control.Monad (forever)
import Data.Foldable (forM_)

-- | Spawn a process waiting for 'CommandRequestMessage's and
-- forwarding their content to RC.
start :: SendPort CommandResponseMessage
      -> Process ProcessId
start sp = spawnLocal $ forever $ do
  cr <- expect
  let CommandRequestMessage _ _ msr msgId = commandRequestMessage cr
  self <- getSelfPid
  forM_ msr $ \req -> do
    _ <- promulgate (req, msgId, self)
    rep <- expect
    sendChan sp rep
