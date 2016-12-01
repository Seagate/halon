-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE CPP #-}

module HA.Services.Noisy
  ( noisy
  , NoisyConf(..)
  , HasPingCount(..)
  , NoisyPingCount(..)
  , DummyEvent(..)
  , HA.Services.Noisy.__remoteTable
  , HA.Services.Noisy.__remoteTableDecl
    -- D-P specifics
  , noisy__static
  ) where

import HA.Aeson
import HA.Debug
import HA.EventQueue.Producer
import HA.ResourceGraph
import HA.SafeCopy
import HA.Service
import HA.Service.TH
import HA.Services.Dummy (DummyEvent(..))

#if ! MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad

import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

newtype NoisyConf = NoisyConf {
  pings :: Defaultable String
} deriving (Eq, Generic, Hashable, Show, Typeable)

type instance ServiceState NoisyConf = ProcessId

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
  deriving (Typeable, Eq, Hashable, Show)
deriveSafeCopy 0 'base ''NoisyPingCount

data HasPingCount = HasPingCount
  deriving (Typeable, Generic, Eq, Show)

instance Hashable HasPingCount
deriveSafeCopy 0 'base ''HasPingCount

relationDictHasPingCountServiceNoisyNoisyPingCount :: Dict (
    Relation HasPingCount (Service NoisyConf) NoisyPingCount
 )
relationDictHasPingCountServiceNoisyNoisyPingCount = Dict

resourceDictNoisyPingCount :: Dict (Resource NoisyPingCount)
resourceDictNoisyPingCount = Dict

$(generateDicts ''NoisyConf)
$(deriveService ''NoisyConf 'noisySchema [ 'relationDictHasPingCountServiceNoisyNoisyPingCount
                                         , 'resourceDictNoisyPingCount
                                         ])

instance Relation HasPingCount (Service NoisyConf) NoisyPingCount where
  type CardinalityFrom HasPingCount (Service NoisyConf) NoisyPingCount
    = 'Unbounded
  type CardinalityTo   HasPingCount (Service NoisyConf) NoisyPingCount
    = 'AtMostOne
  relationDict = $(mkStatic 'relationDictHasPingCountServiceNoisyNoisyPingCount)

instance Resource NoisyPingCount where
  resourceDict = $(mkStatic 'resourceDictNoisyPingCount)

remotableDecl [ [d|
  noisy :: Service NoisyConf
  noisy = Service "noisy"
            $(mkStaticClosure 'noisyFunctions)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictNoisyConf))

  noisyFunctions :: ServiceFunctions NoisyConf
  noisyFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where

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
    service (NoisyConf hw) = do -- FIXME: starte before running service
      forM_ [1 .. read (fromDefault hw)] $ \i ->
        promulgate $ DummyEvent $ show (i :: Int)

    confirm _ pid = usend pid ()

  |] ]
