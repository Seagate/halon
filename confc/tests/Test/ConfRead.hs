--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This program prints in stdout the contents of the configuration in confd.
-- Call as: ./testconfc local_rpc_address confd_rpc_address
module Test.ConfRead (test, name) where

import Mero (withM0)
import Mero.Concurrent
import Mero.ConfC

import Network.RPC.RPCLite

import Control.Monad (join)
import System.IO

import Helper

name :: String 
name = "read-configuration-db"

printConf :: String -> String -> IO ()
printConf localAddress confdAddress =
  withEndpoint (rpcAddress localAddress) $ \ep -> do
    hPutStrLn stderr "Opened endpoint"
    rpcMach <- getRPCMachine_se ep
    withConf rpcMach (rpcAddress confdAddress) $ \rootNode -> do
      hPutStrLn stderr "Opened confc"
      printErr rootNode
      profiles <- (children :: Root -> IO [Profile]) rootNode
      printErr profiles
      fs <- join <$> mapM (children :: Profile -> IO [Filesystem]) profiles
      printErr fs
      nodes <- join <$> mapM (children :: Filesystem -> IO [Node]) fs
      printErr nodes
      pools <- join <$> mapM (children :: Filesystem -> IO [Pool]) fs
      printErr pools
      racks <- join <$> mapM (children :: Filesystem -> IO [Rack]) fs
      printErr racks
      pver <- join <$> mapM (children :: Pool -> IO [PVer]) pools
      printErr pver
      rackv <- join <$> mapM (children :: PVer -> IO [RackV]) pver
      printErr rackv
      enclv <- join <$> mapM (children :: RackV -> IO [EnclV]) rackv
      printErr enclv
      ctrlv <- join <$> mapM (children :: EnclV -> IO [CtrlV]) enclv
      printErr ctrlv
      diskv <- join <$> mapM (children :: CtrlV -> IO [DiskV]) ctrlv
      printErr diskv
      processes <- join <$> mapM (children :: Node -> IO [Process]) nodes
      printErr processes
      services <- join <$> mapM (children :: Process -> IO [Service]) processes
      printErr services
      sdevs <- join <$> mapM (children :: Service -> IO [Sdev]) services
      printErr sdevs
      encls <- join <$> mapM (children :: Rack -> IO [Enclosure]) racks
      printErr encls
      ctrls <- join <$> mapM (children :: Enclosure -> IO [Controller]) encls
      printErr ctrls
      disks <- join <$> mapM (children :: Controller -> IO [Disk]) ctrls
      printErr disks
      desv2 <- join <$> mapM (children :: Disk -> IO [Sdev]) disks
      printErr desv2
    hPutStrLn stderr "Closed confc"

test :: IO ()
test = withM0 $ do
    initRPC
    m0t <- forkM0OS $ join $ printConf <$> getHalonEndpoint 
                                       <*> getConfdEndpoint
    joinM0OS m0t
    finalizeRPC
