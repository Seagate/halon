-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Main functions to run 'Test's.

module Test.Driver
    ( defaultMain
    , defaultMainWith
    ) where

import Test.Tasty
import System.Environment ( getArgs, withArgs )


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
defaultMainWith ::
    ([String] -> IO TestTree)
    -- ^ Action taking list of 'String' from stdarg and returning
    -- 'Test's to run.
    -> IO ()
defaultMainWith tests = do
    args <- getArgs
    let (args',rest) = break (=="--") args
    tests (drop 1 rest) >>= withArgs args' . defaultMain
