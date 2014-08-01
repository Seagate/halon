-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A complicated example, in which nodes join or leave the network
-- intermittently.
-- 

module Main where

import NodeController
import Nodes
import Viewer

import FRP.Sodium
import FRP.Sodium.Util (timeLoop)

import Control.Distributed.Process.Node
  (newLocalNode, forkProcess, initRemoteTable)
import Network.CEP.Broker.Centralized (broker)

import Network.CEP.Processor
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Control.Concurrent (forkIO)
import Data.Time (getCurrentTime)

main :: IO ()
main = do
    Right transport  <- createTransport "127.0.0.1" "8898" defaultTCPParameters
    brokerPid        <- newLocalNode transport initRemoteTable
                          >>= flip forkProcess broker
    (time, pushTime) <- sync newEvent
    now              <- getCurrentTime >>= sync . flip hold time
    let config = Config [brokerPid]
    mapM_ forkIO [ spawnNodes now transport config
                 , runProcessor transport config (averageTemperature now)
                 , runProcessor transport config viewer ]
    timeLoop 0.05 . const $ getCurrentTime >>= sync . pushTime

