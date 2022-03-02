-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
-- A very simple example of using the callback interface to CEP.
--

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import Network.CEP

import Control.Distributed.Process.Closure (mkStatic, remotable)
import Control.Distributed.Process.Node
  (newLocalNode, forkProcess, initRemoteTable)
import Control.Lens
import Control.Monad.Trans (liftIO)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Control.Applicative ((<$))
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void)

sinstString :: Instance (Statically Emittable) String
sinstInt    :: Instance (Statically Emittable) Int
(sinstString, sinstInt) = (Instance, Instance)
remotable [ 'sinstString, 'sinstInt ]

instance Emittable [Char]
instance Emittable Int

instance Statically Emittable [Char] where
  staticInstance = $(mkStatic 'sinstString)
instance Statically Emittable Int where
  staticInstance = $(mkStatic 'sinstInt)

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
    subscribe $ \(x :: NetworkMessage String) -> do
      intEv . length $ x ^. payload

-- A consumer of Ints.
intPrinter :: Processor s ()
intPrinter = subscribe $ \(x :: NetworkMessage Int) ->
    liftIO . print $ x ^. payload
