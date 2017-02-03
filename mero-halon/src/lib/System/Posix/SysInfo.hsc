-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
module System.Posix.SysInfo
  ( getProcessorCount
  , getMemTotalMB
  , getUserSystemInfo
  , SystemInfo(..)
  , HostHardwareInfo(..)
  , getUserSystemInfo__static
  , getUserSystemInfo__sdict
  , getUserSystemInfo__tdict
  , System.Posix.SysInfo.__remoteTable
  ) where

#include <unistd.h>

import HA.EventQueue (promulgateWait)
import HA.Resources (Node)
import HA.Resources.Mero (HostHardwareInfo(..))
import HA.SafeCopy

import Control.Distributed.Process
import Control.Distributed.Process.Closure (remotable)
import Control.Monad (unless, (<=<))

import Data.Either (isRight)
import Data.Typeable (Typeable)

import GHC.Generics

import System.Process
import System.SystemD.API


#ifdef _SC_NPROCESSORS_ONLN
import Foreign.C
#endif

-- | Query the number of processors available on the system.
getProcessorCount :: IO Int
#ifdef _SC_NPROCESSORS_ONLN
foreign import ccall unsafe "sysconf"
  c_sysconf :: CInt -> IO CLong

-- | Wrapper for C @sysconf(3)@ call.
sysconf :: CInt -> IO Int
sysconf n = do
  r <- throwErrnoIfMinus1 "sysconf" (c_sysconf n)
  return (fromIntegral r)

getProcessorCount = fromIntegral <$> sysconf #{const _SC_NPROCESSORS_ONLN}
#else
getProcessorCount = length . filter (\x -> "processor" `isPrefix` x) <$> readFile "/proc/cpuinfo"
#endif

-- | Get amount of available memory on the system in MiB.
getMemTotalMB :: IO Int
getMemTotalMB = do
  (memtotal:_) <- lines <$> readFile "/proc/meminfo"
  let (_:m:_) = words memtotal
  return $ floor $ (read m :: Double) / 1024

-- | Hardware information about a 'Node'.
data SystemInfo = SystemInfo Node HostHardwareInfo
  deriving (Eq, Show, Typeable, Generic)
deriveSafeCopy 0 'base ''SystemInfo

-- | Load information about system hardware. Reply is sent via 'promulgate'.
getUserSystemInfo :: Node -> Process ()
getUserSystemInfo nid = do
  say "In getUserSystemInfo"
  promulgateWait <=< liftIO $ SystemInfo nid <$>
    (HostHardwareInfo <$> fmap fromIntegral getMemTotalMB <*> getProcessorCount <*> getLNetID)
  say "Post getUserSystemInfo"

-- | Start @lnet@ service, query node IDs and return the first one reported.
--
-- Errors if service fails to start or no IDs are returned.
getLNetID :: IO String
getLNetID = do
  rc <- startService "lnet"
  unless (isRight rc) $ error "failed start lnet module"
  (nid:rest) <- lines <$> readProcess "lctl" ["list_nids"] ""
  unless (null rest) $ putStrLn "lctl reports many interfaces, but only first will be used"
  return nid

remotable [ 'getUserSystemInfo ]
