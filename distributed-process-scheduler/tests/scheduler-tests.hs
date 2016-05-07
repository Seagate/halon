-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.

import qualified TestSuite (main)

import System.Posix.Env (setEnv)

main :: IO ()
main = do
  setEnv "DP_SCHEDULER_ENABLED" "1" True
  TestSuite.main
