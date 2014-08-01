-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A very simple example of using the callback interface to CEP.
-- 

{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Network.CEP.Broker.Centralized (broker)
import Network.CEP.Processor
  (Processor, runProcessor, Config (Config), actionRunner)
import Network.CEP.Processor.Callback (publish, subscribe)
import Network.CEP.Types (NetworkMessage, payload)

import Control.Distributed.Process.Node
  (newLocalNode, forkProcess, initRemoteTable)
import Control.Lens
import Control.Monad.Trans (liftIO)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Control.Applicative ((<$))
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void)

main :: IO ()
main = do
    Right transport <- createTransport "127.0.0.1" "8887" defaultTCPParameters
    brokerPid       <- newLocalNode transport initRemoteTable
                         >>= flip forkProcess broker
    void . forkIO $ runProcessor transport (Config [brokerPid]) stringEmitter
    void . forkIO $ runProcessor transport (Config [brokerPid]) countProcessor
    runProcessor transport (Config [brokerPid]) intPrinter

-- A producer of Strings.
stringEmitter :: Processor s ()
stringEmitter = do
    strEv <- publish
    ar    <- actionRunner
    liftIO . void . forkIO . forever $ do
      threadDelay 1000000
      ar $ True <$ strEv "hello"

-- A processor that takes Strings and produces Ints.
countProcessor :: Processor s ()
countProcessor = do
    intEv <- publish
    subscribe $ \ (x :: NetworkMessage String) -> do
      intEv . length $ x ^. payload

-- A consumer of Ints.
intPrinter :: Processor s ()
intPrinter = subscribe $ \ (x :: NetworkMessage Int) ->
    liftIO . print $ x ^. payload
