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

import HA.EventQueue.Producer (promulgateWait)
import HA.Resources (Node)
import HA.Resources.Mero (HostHardwareInfo(..))

import Control.Distributed.Process
import Control.Distributed.Process.Closure (remotable)
import Control.Monad (unless, (<=<))

import Data.Binary (Binary)
import Data.Either (isRight)
import Data.Typeable (Typeable)

import GHC.Generics

import System.Process
import System.SystemD.API


#ifdef _SC_NPROCESSORS_ONLN
import Foreign.C
#endif

getProcessorCount :: IO Int
#ifdef _SC_NPROCESSORS_ONLN
foreign import ccall unsafe "sysconf"
  c_sysconf :: CInt -> IO CLong

sysconf :: CInt -> IO Int
sysconf n = do
  r <- throwErrnoIfMinus1 "sysconf" (c_sysconf n)
  return (fromIntegral r)

getProcessorCount = fromIntegral <$> sysconf #{const _SC_NPROCESSORS_ONLN}
#else
getProcessorCount = length . filter (\x -> "processor" `isPrefix` x) <$> readFile "/proc/cpuinfo"
#endif

getMemTotalMB :: IO Int
getMemTotalMB = do
  (memtotal:_) <- lines <$> readFile "/proc/meminfo"
  let (_:m:_) = words memtotal
  return $ floor $ (read m :: Double) / 1024

data SystemInfo = SystemInfo Node HostHardwareInfo
  deriving (Eq, Show, Typeable, Generic)

instance Binary SystemInfo

data ServerInfo = ServerInfo Node HostHardwareInfo
  deriving (Eq, Show, Typeable, Generic)

instance Binary ServerInfo


-- | Load information about system hardware. Reply is sent via 'promulgate'.
getUserSystemInfo :: Node -> Process ()
getUserSystemInfo nid = do
  say "In getUserSystemInfo"
  promulgateWait <=< liftIO $ SystemInfo nid <$>
    (HostHardwareInfo <$> fmap fromIntegral getMemTotalMB <*> getProcessorCount <*> getLNetID)
  say "Post getUserSystemInfo"

getLNetID :: IO String
getLNetID = do
  rc <- startService "lnet"
  unless (isRight rc) $ error "failed start lnet module"
  (nid:rest) <- lines <$> readProcess "lctl" ["list_nids"] ""
  unless (null rest) $ putStrLn "lctl reports many interfaces, but only fist will be used"
  return nid

remotable [ 'getUserSystemInfo ]
