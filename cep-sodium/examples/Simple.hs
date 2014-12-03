-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- A simple example showing the use of cep-sodium.  Simply listens for
-- String events and publishes Int events with their lengths.
--

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import Network.CEP (broker)
import Network.CEP.Processor.Sodium

import Control.Distributed.Process.Node
  (newLocalNode, forkProcess, initRemoteTable)
import Control.Distributed.Process.Closure (remotable, mkStatic)
import Control.Lens
import FRP.Sodium
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Control.Applicative

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
    runProcessor transport (Config [brokerPid]) countProcessor

countProcessor :: Processor s ()
countProcessor = do
    strEvt <- subscribe
    intVal <- liftReactive $ fmap length <$> hold "" ((^. payload) <$> strEvt)
    publish $ value intVal
