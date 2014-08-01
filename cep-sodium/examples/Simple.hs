-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A simple example showing the use of cep-sodium.  Simply listens for
-- String events and publishes Int events with their lengths.
-- 

module Main where

import Network.CEP.Processor.Sodium
import Network.CEP.Broker.Centralized (broker)

import Control.Distributed.Process.Node
  (newLocalNode, forkProcess, initRemoteTable)
import Control.Lens
import FRP.Sodium
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Control.Applicative

main :: IO ()
main = do
    Right transport <- createTransport "127.0.0.1" "8887" defaultTCPParameters
    brokerPid       <- newLocalNode transport initRemoteTable
                         >>= flip forkProcess broker
    runProcessor transport (Config [brokerPid]) countProcessor

countProcessor :: Processor s ()
countProcessor = do
    strEvt <- subscribe
    intVal <- liftReactive $ fmap length <$> hold "" ((^. payload) <$> strEvt)
    publish $ value intVal

