-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Should import qualified.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module HA.Services.Dummy
  ( dummy
  , DummyConf(..)
  -- * D-P specific functions
  , HA.Services.Dummy.__remoteTable
  , HA.Services.Dummy.__remoteTableDecl
  , HA.Services.Dummy.__resourcesTable
  , dummy__static
  , interface
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static ( staticApply )
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Aeson
import HA.SafeCopy
import HA.Service
import HA.Service.Interface
import HA.Service.TH
import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

newtype DummyConf = DummyConf {
  helloWorld :: Defaultable String
} deriving (Eq, Generic, Hashable, Show, Typeable)

instance ToJSON DummyConf where
  toJSON (DummyConf h) = object [ "hello_string" .= fromDefault h ]

dummySchema :: Schema DummyConf
dummySchema = let
    hw = defaultable "Hello World!" . strOption $ long "helloWorld"
                <> short 'm'
                <> metavar "GREETING"
  in DummyConf <$> hw

type instance ServiceState DummyConf = ()

instance StorageIndex DummyConf where
  typeKey _ = $(mkUUID "a2911b98-81c8-469d-acff-6ee4f428ce6b")
instance StorageIndex (Service DummyConf) where
  typeKey _ = $(mkUUID "50cfc6db-0e74-4c84-bef9-3dc2fec6854b")
$(generateDicts ''DummyConf)
$(deriveService ''DummyConf 'dummySchema [])
deriveSafeCopy 0 'base ''DummyConf

interface :: Interface () ()
interface = Interface
  { ifVersion = 0
  , ifServiceName = "dummy"
  , ifEncodeToSvc = \_ _ -> Nothing
  , ifDecodeToSvc = \_ -> DecodeFailed "no implementation"
  , ifEncodeFromSvc = \_ _ -> Nothing
  , ifDecodeFromSvc = \_ -> DecodeFailed "no implementation"
  }

remotableDecl [ [d|
  dummy :: Service DummyConf
  dummy = Service (ifServiceName interface)
            $(mkStaticClosure 'dummyFunctions)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictDummyConf))

  dummyFunctions :: ServiceFunctions DummyConf
  dummyFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where
    bootstrap _ = do
      say $ "Starting service dummy"
      return (Right ())
    mainloop _ _ = return []
    teardown _ _ = return ()
    confirm  _ _ = return ()
  |] ]

instance HasInterface DummyConf where
  type ToSvc DummyConf = ()
  type FromSvc DummyConf = ()
  getInterface _ = interface
