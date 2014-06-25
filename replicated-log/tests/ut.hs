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
   -- XXX: if it is possible then move all invocation logic to the test suites.
   runWithArgs ["--pattern","ut","--num-threads","1"] []
   runWithArgs ["--pattern","durability","--num-threads","1"] ["FirstPass"]
   runWithArgs ["--pattern","durability","--num-threads","1"] ["SecondPass"]

orDefault :: [a] -> [a] -> [a]
orDefault [] x = x
orDefault x  _ = x
