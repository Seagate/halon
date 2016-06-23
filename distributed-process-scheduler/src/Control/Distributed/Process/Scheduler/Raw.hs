-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This module reexports the interface in distributed-process unwrapped.
--
-- It could be convenient to circumvent the scheduler if some parts of the
-- application are not intended to use it.

{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process.Scheduler.Raw
    (module Control.Distributed.Process) where

import "distributed-process" Control.Distributed.Process
