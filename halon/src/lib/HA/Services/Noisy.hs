-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Noisy
  ( noisy
  , NoisyConf(..)
  , HasPingCount(..)
  , NoisyPingCount(..)
  , HA.Services.Noisy.__remoteTable
  , HA.Services.Noisy.__remoteTableDecl
  ) where

import HA.EventQueue.Producer
import HA.NodeAgent.Messages
import HA.ResourceGraph
import HA.Service
import HA.Service.TH

#if ! MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Concurrent (newEmptyMVar, takeMVar)
import Control.Monad (replicateM_)

import Data.Binary (Binary)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

newtype NoisyConf = NoisyConf {
  pings :: Defaultable String
} deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

noisySchema :: Schema NoisyConf
noisySchema = let
    hw = defaultable "1" . strOption $ long "pings"
                <> short 'n'
                <> metavar "NUMBER"
  in NoisyConf <$> hw

newtype NoisyPingCount = NoisyPingCount Int
  deriving (Typeable, Binary, Eq, Hashable, Show)

data HasPingCount = HasPingCount
  deriving (Typeable, Generic, Eq, Show)

instance Binary HasPingCount
instance Hashable HasPingCount

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
never = do
    say "NOISY ---------> I DID WHAT I'VE TOLD TO DO !!!!!"
    liftIO $ newEmptyMVar >>= takeMVar

remotableDecl [ [d|
  noisy :: Service NoisyConf
  noisy = Service
            (ServiceName "noisy")
            $(mkStaticClosure 'noisyProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictNoisyConf))

  noisyProcess :: NoisyConf -> Process ()
  noisyProcess (NoisyConf hw) = (`catchExit` onExit) $ do
      say $ "Starting service noisy"
      say $ fromDefault hw
      replicateM_ (read $ fromDefault hw) $ promulgate DummyEvent
      never
    where
      onExit _ Shutdown = say $ "NoisyService stopped."
      onExit _ Reconfigure = say $ "NoisyService reconfigured."

  |] ]
