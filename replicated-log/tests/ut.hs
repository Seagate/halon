-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

import Test (tests)

import Test.Driver
import Test.Tasty (testGroup)
import Test.Tasty.Environment

main :: IO ()
main = do
   (testArgs, runnerArgs) <- parseArgs
   let runWithArgs t r =
         defaultMainWithArgs (fmap (testGroup "replicated-log") . tests)
                             (testArgs `orDefault` t) (runnerArgs `orDefault` r)
   runWithArgs [] ["--tcp-transport"]
   runWithArgs [] [] -- in memory transport

orDefault :: [a] -> [a] -> [a]
orDefault [] x = x
orDefault x  _ = x
