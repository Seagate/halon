-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.

import qualified Tests (main)

import System.Posix.Env (setEnv)

main :: IO ()
main = do
  setEnv "DP_SCHEDULER_ENABLED" "0" True
  Tests.main
