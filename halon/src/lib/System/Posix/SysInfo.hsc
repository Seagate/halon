{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell          #-}
-- |
-- Module    : System.Posix.SysInfo
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Runtime querying of hardware information.
module System.Posix.SysInfo
  ( getProcessorCount
  , getMemTotalMB
  , SysInfo(..)
  ) where

#include <unistd.h>

import qualified Data.Text as T
import Data.Typeable (Typeable)
import Data.Word (Word64)
import Foreign.C
import GHC.Generics
import HA.SafeCopy

foreign import ccall unsafe "sysconf"
  c_sysconf :: CInt -> IO CLong

-- | System information about a node.
data SysInfo = SysInfo
  { -- | Node FQDN.
    _si_hostname :: !T.Text
    -- | Memory in MiB.
  , _si_memMiB :: !Word64
    -- | Number of available CPUs at time of query.
  , _si_cpus :: !Int
  } deriving (Show, Eq, Ord, Typeable, Generic)

-- | Wrapper for C @sysconf(3)@ call.
sysconf :: CInt -> IO Int
sysconf n = do
  r <- throwErrnoIfMinus1 "sysconf" (c_sysconf n)
  return $! fromIntegral r

-- | Query the number of processors available on the system.
getProcessorCount :: IO Int
getProcessorCount = sysconf #{const _SC_NPROCESSORS_ONLN}

-- | Get amount of available memory on the system in MiB.
getMemTotalMB :: IO Word64
getMemTotalMB = do
  pages <- sysconf #{const _SC_PHYS_PAGES}
  pageSize <- sysconf #{const _SC_PAGE_SIZE}
  return $! floor $ fromIntegral (pages * pageSize) / 1024 / (1024 :: Double)

deriveSafeCopy 0 'base ''SysInfo
