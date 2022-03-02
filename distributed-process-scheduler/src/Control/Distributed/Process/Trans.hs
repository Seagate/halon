-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

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
