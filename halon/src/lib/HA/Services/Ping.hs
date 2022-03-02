{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}
-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Should import qualified, used for testing service-related functionality.
module HA.Services.Ping
  ( ping
  , PingConf(..)
  , PingSvcEvent(..)
  , HA.Services.Ping.__remoteTable
  , HA.Services.Ping.__remoteTableDecl
  , HA.Services.Ping.__resourcesTable
  , ping__static
  , interface_v0
  , interface_v1
  , interface_v2
  , defaultConf
  ) where

import Control.Distributed.Process.Closure
import Control.Distributed.Static ( staticApply )
import Data.Function (fix)
import Data.Hashable (Hashable)
import Data.List (isSuffixOf)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Aeson
import HA.SafeCopy hiding (Version)
import HA.Service
import HA.Service.Interface
import HA.Service.TH
import Options.Schema (Schema)


-- | Ping service configuration indicates what version of the
-- interface to use.
data PingConf = PingConf_v0
              | PingConf_v1
              | PingConf_v2
  deriving (Eq, Generic, Show, Typeable)

defaultConf :: PingConf
defaultConf = PingConf_v1

pingSchema :: Schema PingConf
pingSchema = pure defaultConf

instance Hashable PingConf
instance ToJSON PingConf

type instance ServiceState PingConf = ()

instance StorageIndex PingConf where
  typeKey _ = $(mkUUID "3f63d148-37a3-4dd5-a2af-74aff8f2805b")
instance StorageIndex (Service PingConf) where
  typeKey _ = $(mkUUID "1d1787a9-3dce-4131-bb44-e7090cd864e6")
$(generateDicts ''PingConf)
$(deriveService ''PingConf 'pingSchema [])
deriveSafeCopy 0 'base ''PingConf

-- | Pick interface version based on service configuration. This
-- allows us to pretend we have different service versions (which
-- different by which interface they use) on one setup.
confToIface :: PingConf -> Interface PingSvcEvent PingSvcEvent
confToIface PingConf_v0 = interface_v0
confToIface PingConf_v1 = interface_v1
confToIface PingConf_v2 = interface_v2

data PingSvcEvent =
  DummyEvent String
  -- ^ An event which produces no action in the RC. Used for testing.
  | SyncPing String
  -- ^ An event that causes the RC to write pending changes to the RG.
  deriving (Eq, Show, Typeable, Generic)

-- | Generate an interface for ping service with a quirk: it adds a
-- suffix with its version to every message it sends and strips it
-- from every message it receives. This means to get the same result
-- back from the service, we need to use the correct interface which
-- allows for testing across versions.
quirky_interface :: Version
                 -- ^ Interface version
                 -> (Version -> Maybe (Interface PingSvcEvent PingSvcEvent))
                 -- ^ Potential different interface to use with other versions.
                 -> Interface PingSvcEvent PingSvcEvent
quirky_interface v'@(Version vnum) otherVerIf = fix $ \interface -> Interface
  { ifVersion = v'
  , ifServiceName = "ping"
  , ifEncodeToSvc = \v m -> case otherVerIf v of
      Nothing -> Just . safeEncode interface $ onEvent (++ suf) m
      Just interface' -> ifEncodeToSvc interface' v m
  , ifDecodeToSvc = \wf -> case otherVerIf $! wfSenderVersion wf of
      Nothing -> onEvent drop_suf <$> safeDecode wf
      Just interface' -> ifDecodeToSvc interface' wf
  , ifEncodeFromSvc = \v m -> case otherVerIf v of
      Nothing -> Just . safeEncode interface $ onEvent (++ suf) m
      Just interface' -> ifEncodeFromSvc interface' v m
  , ifDecodeFromSvc = \wf -> case otherVerIf $! wfSenderVersion wf of
      Nothing -> onEvent drop_suf <$> safeDecode wf
      Just interface' -> ifDecodeFromSvc interface' wf
  }
  where
    onEvent :: (String -> String) -> PingSvcEvent -> PingSvcEvent
    onEvent f (DummyEvent s) = DummyEvent $! f s
    onEvent f (SyncPing s) = SyncPing $! f s

    suf = "_v" ++ show vnum
    drop_suf s = if suf `isSuffixOf` s
                 then take (length s - length suf) s
                 else s

interface_v0 :: Interface PingSvcEvent PingSvcEvent
interface_v0 = quirky_interface 0 (\_ -> Nothing)

interface_v1 :: Interface PingSvcEvent PingSvcEvent
interface_v1 = quirky_interface 1 $ \case
  0 -> Just interface_v0
  _ -> Nothing

interface_v2 :: Interface PingSvcEvent PingSvcEvent
interface_v2 = quirky_interface 2 $ \case
  0 -> Just interface_v0
  1 -> Just interface_v1
  _ -> Nothing

remotableDecl [ [d|
  ping :: Service PingConf
  ping = Service (ifServiceName (getInterface ping))
            $(mkStaticClosure 'pingFunctions)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictPingConf))

  pingFunctions :: ServiceFunctions PingConf
  pingFunctions = ServiceFunctions bootstrap mainloop teardown confirm where

    bootstrap _ = do
      return (Right ())
    mainloop (confToIface -> interface) _ = return
      [ receiveSvc interface $ \pse -> do
          sendRC interface pse
          return (Continue, ())
      -- These cases are not needed in any normal service because
      -- HA.Service.Internal already inserts returnedFromSvc and
      -- receiveSvcFailure. They are required here for testing so that
      -- we can use the interface chosen by service configuration, not
      -- the interface returned by @getInterface@ that's used in
      -- HA.Service.Internal.
      , returnedFromSvc interface $ do
          return (Continue, ())
      , receiveSvcFailure interface $ do
          return (Continue, ())
      ]
    teardown _ _ = return ()
    confirm  _ _ = return ()

  |] ]

-- | 'interface_v1' is to be used by 'getInterface': this means RC
-- always works with v1 while we are able to start ping service v0 and
-- v2 for testing of message exchanges across versions.
instance HasInterface PingConf where
  type ToSvc PingConf = PingSvcEvent
  type FromSvc PingConf = PingSvcEvent
  getInterface _ = interface_v1

deriveSafeCopy 0 'base ''PingSvcEvent
