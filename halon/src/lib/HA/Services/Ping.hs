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
  , HA.Services.Ping.__resourcesTable
  , ping__static
  ) where

import HA.Aeson
import HA.EventQueue.Producer
import HA.SafeCopy
import HA.Service
import HA.Service.TH
import HA.Services.Dummy (DummyEvent(..))

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )

import Data.Hashable (Hashable)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)


data PingConf = PingConf deriving (Eq, Generic, Show, Typeable)

instance Hashable PingConf
instance ToJSON PingConf

-- | An event that causes the RC to write pending changes to the RG.
newtype SyncPing = SyncPing String
  deriving (Show, Generic, Typeable)
deriveSafeCopy 0 'base ''SyncPing

pingSchema :: Schema PingConf
pingSchema = pure PingConf

type instance ServiceState PingConf = ()

instance StorageIndex PingConf where
  typeKey _ = $(mkUUID "3f63d148-37a3-4dd5-a2af-74aff8f2805b")
instance StorageIndex (Service PingConf) where
  typeKey _ = $(mkUUID "1d1787a9-3dce-4131-bb44-e7090cd864e6")
$(generateDicts ''PingConf)
$(deriveService ''PingConf 'pingSchema [])
deriveSafeCopy 0 'base ''PingConf

remotableDecl [ [d|
  ping :: Service PingConf
  ping = Service "ping"
            $(mkStaticClosure 'pingFunctions)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictPingConf))

  pingFunctions :: ServiceFunctions PingConf
  pingFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where

    bootstrap PingConf = do
      return (Right ())
    mainloop _ _ = return
      [ match $ \x -> do
          promulgateWait (DummyEvent x)
          return (Continue, ())
      , match $ \p -> do
          promulgateWait (p::SyncPing)
          return (Continue, ())
      ]
    teardown _ _ = return ()
    confirm  _ _ = return ()

  |] ]
