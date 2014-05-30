-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
import Test.Unit (tests)

import Test.Driver

#ifdef USE_RPC
import Test.Framework (testSuccess)
import Test.Tasty (testGroup)
import Control.Concurrent ( threadDelay )
#endif


main :: IO ()
main = defaultMainWith getTests
  where
    getTests args = do
        ts <- tests args
#ifdef USE_RPC
        -- TODO: Remove threadDelay after RPC transport closes cleanly
        return $ testGroup "uncleanRPCClose" [ts, testSuccess "" $ threadDelay 2000000]
#else
        return ts
#endif
