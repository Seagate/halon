-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Main functions to run 'Test's.

module Test.Driver
    ( defaultMain
    , defaultMainWith
    , defaultMainWithArgs
    ) where

import Test.Tasty
import Test.Tasty.Environment (parseArgs)
import Test.Tasty.Ingredients.FileReporter
import Test.Tasty.Ingredients.Basic

import System.Environment (withArgs)

-- | Like 'defaultMain', but for tests with extra argument
-- passed at the time of executable invocation. Instead of calling
-- 'getArgs', use this function when arguments from command line are
-- required.
--
-- When invoking the test program:
--
-- > test-program <tasty arguments> -- <other arguments>
--
-- '--' separates the tasty arguments from the rest.
--
defaultMainWith :: ([String] -> IO TestTree)
                -- ^ Action taking a list of 'String' from stdarg and returning
                -- 'Tests's to run.
                -> IO ()
defaultMainWith tests = uncurry (defaultMainWithArgs tests) =<< parseArgs

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
