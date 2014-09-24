-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process.Trans
  ( MonadProcess(..)
  , MatchT
  , matchT
  , matchIfT
  , receiveWaitT
  ) where

import Control.Distributed.Process.Scheduler.Internal
import "distributed-process-trans" Control.Distributed.Process.Trans
  ( MonadProcess(..) )
