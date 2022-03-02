-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Helpers for 'tasty' framework.


module Test.Tasty.Environment
   ( parseArgs
   ) where

import System.Environment (getArgs)

-- | Parse test arguments from the command line.
parseArgs :: IO ([String], [String])
parseArgs = fmap (fmap (drop 1) . span (/= "--")) getArgs
