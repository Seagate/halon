-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

import Test (tests)

import Test.Driver
import Test.Tasty.Environment

main :: IO ()
main = do
   (testArgs, runnerArgs) <- parseArgs
   let runWithArgs t r = defaultMainWithArgs tests (testArgs `orDefault` t) (runnerArgs `orDefault` r)
   runWithArgs ["--num-threads","1"] []

orDefault :: [a] -> [a] -> [a]
orDefault [] x = x
orDefault x  _ = x
