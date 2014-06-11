-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
import Test (tests)

import Test.Tasty
import Test.Tasty.Ingredients.FileReporter
import Test.Tasty.Ingredients.Basic


main :: IO ()
main = tests >>= defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
