-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Ping
  ( ping
  , PingConf(..)
  , HA.Services.Ping.__remoteTable
  , HA.Services.Ping.__remoteTableDecl
  ) where

import HA.EventQueue.Producer
import HA.Service
import HA.Service.TH

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)


data PingConf = PingConf deriving (Eq, Generic, Show, Typeable)

instance Binary PingConf
instance Hashable PingConf

pingSchema :: Schema PingConf
pingSchema = pure PingConf

$(generateDicts ''PingConf)
$(deriveService ''PingConf 'pingSchema [])

remotableDecl [ [d|
  ping :: Service PingConf
  ping = Service
            (ServiceName "ping")
            $(mkStaticClosure 'pingProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictPingConf))

  pingProcess :: PingConf -> Process ()
  pingProcess PingConf = do
      say $ "Starting service ping"
      forever $ expect >>= promulgate . DummyEvent

  |] ]
