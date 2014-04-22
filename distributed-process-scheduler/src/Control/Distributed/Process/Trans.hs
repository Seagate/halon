-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process.Trans
  (
#ifdef USE_DETERMINISTIC_SCHEDULER
    module Control.Distributed.Process.Scheduler.Internal
  , module DPT
#else
    module DPT
#endif
  ) where

#ifdef USE_DETERMINISTIC_SCHEDULER
import Control.Distributed.Process.Scheduler.Internal
  ( MatchT
  , matchT
  , matchIfT
  , receiveWaitT )
#endif
import "distributed-process-trans" Control.Distributed.Process.Trans as DPT
#ifdef USE_DETERMINISTIC_SCHEDULER
    hiding
  ( MatchT
  , matchT
  , matchIfT
  , receiveWaitT )
#endif
