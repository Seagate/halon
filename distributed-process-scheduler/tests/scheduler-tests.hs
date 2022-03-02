-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

import qualified TestSuite (main)

import System.Posix.Env (setEnv)

main :: IO ()
main = do
  setEnv "DP_SCHEDULER_ENABLED" "1" True
  TestSuite.main
