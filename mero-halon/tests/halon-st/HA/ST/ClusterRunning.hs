-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- A /dummy/ test: pass if the cluster is running: that is every node,
-- process and services is in online state. Serves as a template/guide
-- to how to write these tests.
module HA.ST.ClusterRunning (test) where

import HA.ST.Common

test :: HASTTest
test = HASTTest "cluster-running" (return $ Just "error message here")
