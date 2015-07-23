-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Prelude hiding ((<$>))
import Flags
import Lookup

import HA.Network.RemoteTables (haRemoteTable)
import HA.Process

import Handler.Bootstrap
import Handler.Service

import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
#endif

import Control.Applicative ((<$>))
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode)

import Data.List (break)

buildType :: String
#ifdef USE_RPC
buildType = "RPC"
#else
buildType = "TCP"
#endif

printHeader :: IO ()
printHeader =
  putStrLn $ "This is halonctl/" ++ buildType

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO ()
main = getOptions >>= run

run :: Options -> IO ()
run (Options { .. }) = do
#ifdef USE_RPC
  rpcTransport <- RPC.createTransport "s1"
                                      (RPC.rpcAddress $ optOurAddress)
                                      RPC.defaultRPCParameters
  writeTransportGlobalIVar rpcTransport
  let transport = RPC.networkTransport rpcTransport
#else
  let (hostname, port) = tail <$> (break (== ':') optOurAddress)
  transport <- either (error . show) id <$>
               TCP.createTransport hostname port TCP.defaultTCPParameters
#endif
  lnid <- newLocalNode transport myRemoteTable
  let rnids = fmap conjureRemoteNodeId optTheirAddress
  tryRunProcess lnid $ do
    liftIO $ printHeader
    case optCommand of
      Bootstrap bs -> bootstrap rnids bs
      Service bs   -> service rnids bs
  return ()
