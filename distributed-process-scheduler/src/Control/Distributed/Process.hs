-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process
  (
#ifdef USE_DETERMINISTIC_SCHEDULER
    module Control.Distributed.Process.Scheduler.Internal
  , module DP
#else
    module DP
#endif
  ) where

#ifdef USE_DETERMINISTIC_SCHEDULER
import Control.Distributed.Process.Scheduler.Internal
  ( Match
  , send
  , match
  , matchIf
  , expect
  , receiveWait
  , spawnLocal
  , spawn )
#endif
import "distributed-process" Control.Distributed.Process as DP
#ifdef USE_DETERMINISTIC_SCHEDULER
    hiding
  ( Match
  , send
  , match
  , matchIf
  , expect
  , receiveWait
  , spawnLocal
  , spawn )
#endif
