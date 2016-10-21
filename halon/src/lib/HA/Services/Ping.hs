-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module HA.Services.Ping
  ( ping
  , PingConf(..)
  , SyncPing(..)
  , HA.Services.Ping.__remoteTable
  , HA.Services.Ping.__remoteTableDecl
  , ping__static
  , pingProcess__sdict
  , pingProcess__tdict
  ) where

import HA.EventQueue.Producer
import HA.Service
import HA.Service.TH
import HA.Services.Dummy (DummyEvent(..))

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad

import Data.Aeson
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.SafeCopy
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)


data PingConf = PingConf deriving (Eq, Generic, Show, Typeable)

instance Binary PingConf
instance Hashable PingConf
instance ToJSON PingConf

-- | An event that causes the RC to write pending changes to the RG.
newtype SyncPing = SyncPing String
  deriving (Show, Generic, Typeable, Binary)

pingSchema :: Schema PingConf
pingSchema = pure PingConf

$(generateDicts ''PingConf)
$(deriveService ''PingConf 'pingSchema [])
deriveSafeCopy 0 'base ''PingConf

remotableDecl [ [d|
  ping :: Service PingConf
  ping = Service "ping"
            $(mkStaticClosure 'pingProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictPingConf))

  pingProcess :: PingConf -> Process ()
  pingProcess PingConf = do
      say $ "Starting service ping"
      forever $ receiveWait
        [ match $ promulgateWait . DummyEvent
        , match $ \p -> promulgateWait (p :: SyncPing)
        ]
  |] ]
