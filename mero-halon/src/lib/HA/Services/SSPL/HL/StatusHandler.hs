-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.Services.SSPL.HL.StatusHandler where

import HA.EventQueue.Producer (promulgate)
import SSPL.Bindings

import Control.Distributed.Process
  ( Process
  , ProcessId
  , SendPort
  , expect
  , getSelfPid
  , sendChan
  , spawnLocal
  )
import Control.Monad (forever)
import Data.Foldable (forM_)

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
