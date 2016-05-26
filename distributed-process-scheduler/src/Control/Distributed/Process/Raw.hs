-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This module exposes the distributed-process api unwrapped.
-- It could be convenient to circumvent scheduler limitations.

{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process.Raw
    (module Control.Distributed.Process) where

import "distributed-process" Control.Distributed.Process
