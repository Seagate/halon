{-|
Copyright : (C) 2014 Xyratex Technology Limited.
License   : All rights reserved.

Utility functions which do not belong in any particular module.
-}

module HA.Utils
  ( forceSpine
  ) where


{-| @forceSpine xs@ evaluates the spine of @xs@.
-}
forceSpine :: [a] -> [a]
forceSpine xs = forceSpine' xs `seq` xs
{-# INLINE forceSpine #-}

{- Quoted from the stream-fusion package:
http://hackage.haskell.org/package/stream-fusion-0.1.2.5/docs/src/Data-List-Stream.html

The idea of this slightly odd construction is that we inline the above form
and in the context we may then be able to use xs directly and just keep
around the fact that xs must be forced at some point. Remember, seq does not
imply any evaluation order.
-}
forceSpine' :: [a] -> ()
forceSpine' []      = ()
forceSpine' (_ : xs') = forceSpine' xs'
{-# NOINLINE forceSpine' #-}
