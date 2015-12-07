--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Test is based on the test in spiel/st in mero sources.
-- If this script will start failing, first check that spiel/st run
-- correctly and then see if something changed there
module Main where

import Mero (withM0)
import Mero.ConfC
import Mero.Spiel

import Network.RPC.RPCLite
import Control.Exception (bracket)
import Control.Monad (when)
import System.Environment ( getArgs )

import Data.Map (Map)
import Data.Word
import qualified Data.Map as Map
import System.Process

mfids :: Map String Fid
mfids = Map.fromList
 [ ("profile"       , Fid 0x7000000000000001 0)
 , ("fs"            , Fid 0x6600000000000001 1)
 , ("node"          , Fid 0x6e00000000000001 2)
 , ("pool"          , Fid 0x6f00000000000001 9)
 , ("rack"          , Fid 0x6100000000000001 6)
 , ("encl"          , Fid 0x6500000000000001 7)
 , ("ctrl"          , Fid 0x6300000000000001 8)
 , ("disk0"         , Fid 0x6b00000000000001 2)
 , ("disk1"         , Fid 0x6b00000000000001 3)
 , ("disk2"         , Fid 0x6b00000000000001 4)
 , ("disk3"         , Fid 0x6b00000000000001 5)
 , ("pver"          , Fid 0x7600000000000001 10)
 , ("rackv"         , Fid 0x6a00000000000001 2)
 , ("enclv"         , Fid 0x6a00000000000001 3)
 , ("ctrlv"         , Fid 0x6a00000000000001 4)
 , ("diskv0"        , Fid 0x6a00000000000001 5)
 , ("diskv1"        , Fid 0x6a00000000000001 6)
 , ("diskv2"        , Fid 0x6a00000000000001 7)
 , ("diskv3"        , Fid 0x6a00000000000001 8)
 , ("process"       , Fid 0x7200000000000001 3)
 , ("process2"      , Fid 0x7200000000000001 4)
 , ("ios"           , Fid 0x7300000000000002 0)
 , ("mds"           , Fid 0x7300000000000002 2)
 , ("mds2"          , Fid 0x7300000000000002 3)
 , ("addb2"         , Fid 0x7300000000000002 5)
 , ("sns_repair"    , Fid 0x7300000000000002 6)
 , ("sns_rebalance" , Fid 0x7300000000000002 7)
 , ("confd"         , Fid 0x7300000000000002 8)
 , ("confd2"        , Fid 0x7300000000000002 9)
 , ("sdev0"         , Fid 0x6400000000000009 0)
 , ("sdev1"         , Fid 0x6400000000000009 1)
 , ("sdev2"         , Fid 0x6400000000000009 2)
 , ("sdev3"         , Fid 0x6400000000000009 3)
 , ("rms"           , Fid 0x7300000000000004 0)
 , ("ha"            , Fid 0x7300000000000004 4)
 ]

fids :: String -> Fid
fids s = mfids Map.! s

devSize :: Word64
devSize = 1024*1024

main :: IO ()
main = do
  i <- read <$> readCreateProcess (shell "id -u") ""
  when (i /= (0::Int)) $ error "Must be run by superuser"
  lnet_nid <- readCreateProcess (shell "lctl list_nids | head -1") ""
  let server1_endpoint = lnet_nid ++ ":12345:34:1001"
      server2_endpoint = lnet_nid ++ ":12345:34:1002"
  [localAddress, confdAddress, rmAddress] <- getArgs 
  withM0 $ do
    initRPC
    withEndpoint (rpcAddress localAddress) $ \ep -> do
      rpcMach <- getRPCMachine_se ep
      withConf rpcMach (rpcAddress confdAddress) $ \_ -> do
        withSpiel rpcMach [confdAddress] rmAddress $ \spiel -> do
          withTransaction spiel $ \tx -> do
            addProfile tx (fids "profile")
            addFilesystem tx (fids "fs") (fids "profile") 10 (fids "profile") (fids "pool") ["4 2 1"]
            addPool tx (fids "pool") (fids "fs") 2
            addRack tx (fids "rack") (fids "fs")
            addEnclosure tx (fids "encl") (fids "rack")
            addNode tx (fids "node") (fids "fs") 256 2 10 0xff00ff00 (fids "pool")
            addController tx (fids "ctrl") (fids "encl") (fids "node")
            addDisk tx (fids "disk0") (fids "ctrl")
            addDisk tx (fids "disk1") (fids "ctrl")
            addDisk tx (fids "disk2") (fids "ctrl")
            addDisk tx (fids "disk3") (fids "ctrl")
            addPVer tx (fids "pver") (fids "pool") [0, 0, 0, 0, 1] 
              $ PDClustAttr 2 1 4 (1024*1024) (Word128 0x01 0x2)
            addRackV tx (fids "rackv") (fids "pver") (fids "rack")
            addEnclosureV tx (fids "enclv") (fids "rackv") (fids "encl")
            addControllerV tx (fids "ctrlv") (fids "enclv") (fids "ctrl")
            addDiskV tx (fids "diskv0") (fids "ctrlv") (fids "disk0")
            addDiskV tx (fids "diskv1") (fids "ctrlv") (fids "disk1")
            addDiskV tx (fids "diskv2") (fids "ctrlv") (fids "disk2")
            addDiskV tx (fids "diskv3") (fids "ctrlv") (fids "disk3")
            poolVersionDone tx (fids "pver")
            addProcess tx (fids "process")  (fids "node") (Bitmap 2 [3]) 0 0 0 0 server1_endpoint
            addProcess tx (fids "process2") (fids "node") (Bitmap 2 [3]) 0 0 0 0 server2_endpoint
            addService tx (fids "confd")    (fids "process") 
              $ ServiceInfo  CST_MGS [server1_endpoint] (SPConfDBPath server1_endpoint)
            addService tx (fids "confd2")   (fids "process2")
              $ ServiceInfo CST_MGS [server2_endpoint] (SPConfDBPath server1_endpoint)
            addService tx (fids "rms")   (fids "process")
              $ ServiceInfo CST_RMS [server1_endpoint] (SPConfDBPath server1_endpoint)
            addService tx (fids "ha")    (fids "process2")
              $ ServiceInfo CST_HA [server2_endpoint] SPUnused
            addService tx (fids "ios")    (fids "process2")
              $ ServiceInfo CST_HA [server2_endpoint] SPUnused
            addService tx (fids "sns_repair") (fids "process2")
              $ ServiceInfo CST_SNS_REP [server2_endpoint] SPUnused
            addService tx (fids "addb2") (fids "process2")
              $ ServiceInfo CST_ADDB2 [server2_endpoint] SPUnused
            addService tx (fids "sns_rebalance") (fids "process2")
              $ ServiceInfo CST_SNS_REB [server2_endpoint] SPUnused
            addService tx (fids "mds") (fids "process")
              $ ServiceInfo CST_MDS [server1_endpoint] SPUnused
            addService tx (fids "mds2") (fids "process2")
              $ ServiceInfo CST_MDS [server2_endpoint] SPUnused 
            addDevice tx (fids "sdev0") (fids "mds2") (fids "disk0") M0_CFG_DEVICE_INTERFACE_SCSI 
              M0_CFG_DEVICE_MEDIA_SSD 1024 (2 * devSize) 123 0x55 "dev/loop0"
            addDevice tx (fids "sdev1") (fids "ios") (fids "disk1") M0_CFG_DEVICE_INTERFACE_SCSI 
              M0_CFG_DEVICE_MEDIA_SSD 1024 (2 * devSize) 123 0x55 "dev/loop1"
            addDevice tx (fids "sdev2") (fids "ios") (fids "disk2") M0_CFG_DEVICE_INTERFACE_SCSI 
              M0_CFG_DEVICE_MEDIA_SSD 1024 (2 * devSize) 123 0x55 "dev/loop2"
            addDevice tx (fids "sdev3") (fids "ios") (fids "disk3") M0_CFG_DEVICE_INTERFACE_SCSI 
              M0_CFG_DEVICE_MEDIA_SSD 1024 (2 * devSize) 123 0x55 "dev/loop3"
     
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