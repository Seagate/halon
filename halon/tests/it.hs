-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Main where

import Test.Integration (tests)
import Test.Run (runTests)

main :: IO ()
main = runTests tests
