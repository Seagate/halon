--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This program prints in stdout the contents of the configuration in confd.
-- Call as: ./testconfc local_rpc_address confd_rpc_address

import Mero (withM0)
import Mero.Concurrent
import Mero.ConfC

import Network.RPC.RPCLite

import Control.Exception (bracket)
import Control.Monad (join)

import System.Environment ( getArgs )

withEndpoint :: RPCAddress -> (ServerEndpoint -> IO a) -> IO a
withEndpoint addr = bracket
    (listen addr listenCallbacks)
    stopListening
  where
    listenCallbacks = ListenCallbacks
      { receive_callback = \it _ ->  putStr "Received: "
                                      >> unsafeGetFragments it
                                      >>= print
                                      >> return True
      }

printConf :: String -> String -> IO ()
printConf localAddress confdAddress =
  withEndpoint (rpcAddress localAddress) $ \ep -> do
    putStrLn "Opened endpoint"
    rpcMach <- getRPCMachine_se ep
    withConf rpcMach (rpcAddress confdAddress) $ \rootNode -> do
      putStrLn "Opened confc"
      print rootNode
      profiles <- (children :: Root -> IO [Profile]) rootNode
      print profiles
      fs <- join <$> mapM (children :: Profile -> IO [Filesystem]) profiles
      print fs
      nodes <- join <$> mapM (children :: Filesystem -> IO [Node]) fs
      print nodes
      pools <- join <$> mapM (children :: Filesystem -> IO [Pool]) fs
      print pools
      racks <- join <$> mapM (children :: Filesystem -> IO [Rack]) fs
      print racks
      pver <- join <$> mapM (children :: Pool -> IO [PVer]) pools
      print pver
      rackv <- join <$> mapM (children :: PVer -> IO [RackV]) pver
      print rackv
      enclv <- join <$> mapM (children :: RackV -> IO [EnclV]) rackv
      print enclv
      ctrlv <- join <$> mapM (children :: EnclV -> IO [CtrlV]) enclv
      print ctrlv
      diskv <- join <$> mapM (children :: CtrlV -> IO [DiskV]) ctrlv
      print diskv
      processes <- join <$> mapM (children :: Node -> IO [Process]) nodes
      print processes
      services <- join <$> mapM (children :: Process -> IO [Service]) processes
      print services
      sdevs <- join <$> mapM (children :: Service -> IO [Sdev]) services
      print sdevs
      encls <- join <$> mapM (children :: Rack -> IO [Enclosure]) racks
      print encls
      ctrls <- join <$> mapM (children :: Enclosure -> IO [Controller]) encls
      print ctrls
      disks <- join <$> mapM (children :: Controller -> IO [Disk]) ctrls
      print disks
      desv2 <- join <$> mapM (children :: Disk -> IO [Sdev]) disks
      print desv2
    putStrLn "Closed confc"

main :: IO ()
main = withM0 $ do
  initRPC
  m0t <- forkM0OS $ do
    getArgs >>= \[ l , c ] -> printConf l c
  joinM0OS m0t
  finalizeRPC
