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
  , PingSvcEvent(..)
  , HA.Services.Ping.__remoteTable
  , HA.Services.Ping.__remoteTableDecl
  , HA.Services.Ping.__resourcesTable
  , ping__static
  , interface
  ) where

import Control.Distributed.Process.Closure
import Control.Distributed.Static ( staticApply )
import Data.Hashable (Hashable)
import Data.Serialize.Get (runGet)
import Data.Serialize.Put (runPut)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Aeson
import HA.SafeCopy
import HA.Service
import HA.Service.Interface
import HA.Service.TH
import Options.Schema (Schema)


data PingConf = PingConf deriving (Eq, Generic, Show, Typeable)

instance Hashable PingConf
instance ToJSON PingConf

data PingSvcEvent =
  DummyEvent String
  -- ^ An event which produces no action in the RC. Used for testing.
  | SyncPing String
  -- ^ An event that causes the RC to write pending changes to the RG.
  deriving (Show, Typeable, Generic)


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

interface :: Interface PingSvcEvent PingSvcEvent
interface = Interface
  { ifVersion = 0
  , ifServiceName = "ping"
  , ifEncodeToSvc = \_v -> Just . mkWf . runPut . safePut
  , ifDecodeToSvc = \wf -> case runGet safeGet $! wfPayload wf of
      Left{} -> Nothing
      Right !v -> Just v
  , ifEncodeFromSvc = \_v -> Just . mkWf . runPut . safePut
  , ifDecodeFromSvc = \wf -> case runGet safeGet $! wfPayload wf of
      Left{} -> Nothing
      Right !v -> Just v
  }
  where
    mkWf payload = WireFormat
      { wfServiceName = ifServiceName interface
      , wfVersion = ifVersion interface
      , wfPayload = payload
      }


remotableDecl [ [d|
  ping :: Service PingConf
  ping = Service (ifServiceName interface)
            $(mkStaticClosure 'pingFunctions)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictPingConf))

  pingFunctions :: ServiceFunctions PingConf
  pingFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where

    bootstrap PingConf = do
      return (Right ())
    mainloop _ _ = return
      [ receiveSvc interface $ \pse -> do
          sendRC interface (pse :: PingSvcEvent)
          return (Continue, ())
      ]
    teardown _ _ = return ()
    confirm  _ _ = return ()

  |] ]

instance HasInterface PingConf PingSvcEvent PingSvcEvent where
  getInterface _ = interface

deriveSafeCopy 0 'base ''PingSvcEvent
