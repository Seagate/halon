-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Initialization and finalization calls of mero.
--
{-# LANGUAGE ForeignFunctionInterface   #-}
module Mero (m0_init, m0_fini, withM0) where

import Control.Exception (bracket_)
import Control.Monad (when)
import Foreign.C.Types (CInt(..))


-- | Initializes mero.
m0_init :: IO ()
m0_init = do
    rc <- m0_init_wrapper
    when (rc /= 0) $
      fail $ "m0_init: failed with " ++ show rc

-- | Encloses an action with calls to 'm0_init' and 'm0_fini'.
withM0 :: IO a -> IO a
withM0 = bracket_ m0_init m0_fini

foreign import ccall m0_init_wrapper :: IO CInt

-- | Finalizes mero.
foreign import ccall m0_fini :: IO ()
