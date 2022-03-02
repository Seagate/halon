-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

import qualified Test (tests)

import Control.Concurrent
import Control.Exception
import Control.Monad
import Test.Tasty
import Test.Tasty.Environment
import Test.Tasty.Ingredients.FileReporter
import Test.Tasty.Ingredients.Basic
import System.Environment (withArgs)


main :: IO ()
main = do
   (testArgs, runnerArgs) <- parseArgs
   let runWithArgs t r =
         defaultMainWithArgs (fmap (testGroup "replicated-log") . Test.tests)
                             (testArgs `orDefault` t) (runnerArgs `orDefault` r)
   tid <- myThreadId
   _ <- forkIO $ do threadDelay (30 * 60 * 1000000)
                    forever $ do threadDelay 100000
                                 throwTo tid (ErrorCall "Timeout")
   runWithArgs [] ["--tcp-transport"]
   runWithArgs [] [] -- in memory transport

orDefault :: [a] -> [a] -> [a]
orDefault [] x = x
orDefault x  _ = x

defaultMainWithArgs :: ([String] -> IO TestTree)
                    -- ^ Action taking a list of 'String' from stdarg and returning
                    -- 'Tests's to run.
                    -> [String]
                    -- ^ Arguments to pass to tast framework.
                    -> [String]
                    -- ^ Arguments to pass to test creation action.
                    -> IO ()
defaultMainWithArgs tests runnerArgs testArgs = do
    tests testArgs >>= withArgs runnerArgs .
      defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
