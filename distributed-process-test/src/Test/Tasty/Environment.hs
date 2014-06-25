-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Helpers for 'tasty' framework.


module Test.Tasty.Environment
   ( parseArgs
   ) where

import System.Environment (getArgs)

-- | Parse test arguments from the command line.
parseArgs :: IO ([String], [String])
parseArgs = fmap (fmap (drop 1) . span (/= "--")) getArgs
