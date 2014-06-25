-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Main where

import Test.Unit (tests)
import Test.Run (runTests)

main :: IO ()
main = runTests tests
