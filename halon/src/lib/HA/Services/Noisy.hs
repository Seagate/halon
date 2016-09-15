-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
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
  , noisyProcess__sdict
  , noisyProcess__tdict
  ) where

import HA.EventQueue.Producer
import HA.ResourceGraph
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

import Data.Aeson
import Data.Binary (Binary)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.SafeCopy
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

newtype NoisyConf = NoisyConf {
  pings :: Defaultable String
} deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

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
  deriving (Typeable, Binary, Eq, Hashable, Show)
deriveSafeCopy 0 'base ''NoisyPingCount

data HasPingCount = HasPingCount
  deriving (Typeable, Generic, Eq, Show)

instance Binary HasPingCount
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
  relationDict = $(mkStatic 'relationDictHasPingCountServiceNoisyNoisyPingCount)

instance Resource NoisyPingCount where
  resourceDict = $(mkStatic 'resourceDictNoisyPingCount)

-- | Block forever.
never :: Process ()
never = receiveWait []

remotableDecl [ [d|
  noisy :: Service NoisyConf
  noisy = Service "noisy"
            $(mkStaticClosure 'noisyProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictNoisyConf))

  noisyProcess :: NoisyConf -> Process ()
  noisyProcess (NoisyConf hw) = do
      say $ "Starting service noisy"
      say $ fromDefault hw
      forM_ [1 .. read (fromDefault hw)] $ \i ->
        promulgate $ DummyEvent $ show (i :: Int)
      never

  |] ]
