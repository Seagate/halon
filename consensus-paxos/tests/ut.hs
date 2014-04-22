-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
import Test (tests)

import Test.Driver


main :: IO ()
main = tests >>= defaultMain
