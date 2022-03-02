-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Helper functions for implementing spine strict functions.
module Control.SpineSeq
  ( spineSeq
  ) where


-- | @spineSeq xs@ evaluates the spine of @xs@.
spineSeq :: [a] -> [a]
spineSeq xs = spineSeq' xs `seq` xs
{-# INLINE spineSeq #-}

-- Quoted from the stream-fusion package:
-- http://hackage.haskell.org/package/stream-fusion-0.1.2.5/docs/src/
-- Data-List-Stream.html
--
-- The idea of this slightly odd construction is that we inline the above
-- form and in the context we may then be able to use xs directly and just
-- keep around the fact that xs must be forced at some point. Remember, seq
-- does not imply any evaluation order.

spineSeq' :: [a] -> ()
spineSeq' []        = ()
spineSeq' (_ : xs') = spineSeq' xs'
{-# NOINLINE spineSeq' #-}
