-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Should import qualified.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module HA.Services.Noisy
  ( HasPingCount(..)
  , NoisyConf(..)
  , NoisyPingCount(..)
  , interface
  , noisy
    -- D-P specifics
  , HA.Services.Noisy.__remoteTable
  , HA.Services.Noisy.__remoteTableDecl
  , HA.Services.Noisy.__resourcesTable
  , noisy__static
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static ( staticApply )
import Control.Monad
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Aeson
import HA.Debug
import HA.ResourceGraph
import HA.SafeCopy
import HA.Service
import HA.Service.Interface
import HA.Service.TH
import HA.Services.Ping (PingSvcEvent(..))
import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

newtype NoisyConf = NoisyConf {
  pings :: Defaultable String
} deriving (Eq, Generic, Hashable, Show, Typeable)

type instance ServiceState NoisyConf = ProcessId

instance StorageIndex NoisyConf where
  typeKey _ = $(mkUUID "abc851c4-fe63-4f5a-8fca-5d4750765b05")
instance StorageIndex (Service NoisyConf) where
  typeKey _ = $(mkUUID "f14d533f-a554-4c7a-be6c-932cdfd3c034")

deriveSafeCopy 0 'base ''NoisyConf
instance ToJSON NoisyConf where
  toJSON (NoisyConf pings) = object [ "pings" .= fromDefault pings ]

noisySchema :: Schema NoisyConf
noisySchema = let
    hw = defaultable "1" . strOption $ long "pings"
                <> short 'n'
                <> metavar "NUMBER"
  in NoisyConf <$> hw

newtype NoisyPingCount = NoisyPingCount Int
  deriving (Typeable, Eq, Hashable, Show, Generic)
instance StorageIndex NoisyPingCount where
  typeKey _ = $(mkUUID "95568b9e-d0e3-4297-a436-d8fc7534f76b")
deriveSafeCopy 0 'base ''NoisyPingCount
instance ToJSON NoisyPingCount

data HasPingCount = HasPingCount
  deriving (Typeable, Generic, Eq, Show)

instance Hashable HasPingCount
instance StorageIndex HasPingCount where
  typeKey _ = $(mkUUID "6319647a-7667-4808-a002-f97375cca4df")
deriveSafeCopy 0 'base ''HasPingCount
instance ToJSON HasPingCount

relationDictHasPingCountServiceNoisyNoisyPingCount :: Dict (
    Relation HasPingCount (Service NoisyConf) NoisyPingCount
 )
relationDictHasPingCountServiceNoisyNoisyPingCount = Dict

storageDictHasPingCountServiceNoisyNoisyPingCount :: Dict (
    StorageRelation HasPingCount (Service NoisyConf) NoisyPingCount
 )
storageDictHasPingCountServiceNoisyNoisyPingCount = Dict

resourceDictNoisyPingCount :: Dict (Resource NoisyPingCount)
resourceDictNoisyPingCount = Dict

storageDictNoisyPingCount :: Dict (StorageResource NoisyPingCount)
storageDictNoisyPingCount = Dict

storageDictHasPingCount :: Dict (StorageResource HasPingCount)
storageDictHasPingCount = Dict

$(generateDicts ''NoisyConf)
$(deriveService ''NoisyConf 'noisySchema [ 'relationDictHasPingCountServiceNoisyNoisyPingCount
                                         , 'storageDictHasPingCountServiceNoisyNoisyPingCount
                                         , 'resourceDictNoisyPingCount
                                         , 'storageDictNoisyPingCount
                                         , 'storageDictHasPingCount
                                         ])

instance StorageRelation HasPingCount (Service NoisyConf) NoisyPingCount where
  storageRelationDict = $(mkStatic 'storageDictHasPingCountServiceNoisyNoisyPingCount)

instance Relation HasPingCount (Service NoisyConf) NoisyPingCount where
  type CardinalityFrom HasPingCount (Service NoisyConf) NoisyPingCount
    = 'Unbounded
  type CardinalityTo   HasPingCount (Service NoisyConf) NoisyPingCount
    = 'AtMostOne
  relationDict = $(mkStatic 'relationDictHasPingCountServiceNoisyNoisyPingCount)

instance StorageResource HasPingCount where
  storageResourceDict = $(mkStatic 'storageDictHasPingCount)

instance Resource NoisyPingCount where
  resourceDict = $(mkStatic 'resourceDictNoisyPingCount)

instance StorageResource NoisyPingCount where
  storageResourceDict = $(mkStatic 'storageDictNoisyPingCount)

interface :: Interface () PingSvcEvent
interface = Interface
  { ifVersion = 0
  , ifServiceName = "noisy"
  , ifEncodeToSvc = \_ _ -> Nothing
  , ifDecodeToSvc = safeDecode
  , ifEncodeFromSvc = \_v -> Just . safeEncode interface
  , ifDecodeFromSvc = safeDecode
  }

remotableDecl [ [d|
  noisy :: Service NoisyConf
  noisy = Service (ifServiceName interface)
            $(mkStaticClosure 'noisyFunctions)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictNoisyConf))

  noisyFunctions :: ServiceFunctions NoisyConf
  noisyFunctions = ServiceFunctions bootstrap mainloop teardown confirm where

    bootstrap c@(NoisyConf hw) = do
      say $ fromDefault hw
      self <- getSelfPid
      pid <- spawnLocalName "service::noisy::worker" $
        link self >> (expect :: Process ()) >> service c
      return (Right pid)

    mainloop _ pid = return
      [matchIf (\(ProcessMonitorNotification _ p _) -> p == pid)
               $ \_ -> return (Failure, pid)]

    teardown _ _ = return ()

    service :: NoisyConf -> Process ()
    service (NoisyConf hw) = do -- FIXME: started before running service
      forM_ [1 .. read (fromDefault hw)] $ \i -> do
        sendRC interface $! DummyEvent (show (i :: Int))
    confirm _ pid = usend pid ()

  |] ]

instance HasInterface NoisyConf where
  type ToSvc NoisyConf = ()
  type FromSvc NoisyConf = PingSvcEvent
  getInterface _ = interface
