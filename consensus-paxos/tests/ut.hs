-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE CPP #-}
import Test (tests)

import Test.Tasty
import Test.Tasty.Ingredients.FileReporter
import Test.Tasty.Ingredients.Basic


main :: IO ()
main = tests >>= defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
