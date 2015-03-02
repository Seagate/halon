-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

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
import HA.Service
import HA.ResourceGraph
import HA.Resources (Cluster, Node)

import Control.Applicative ((<$>))
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

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

dConfigDict :: Dict (Configuration NoisyConf)
dConfigDict = Dict

dSerializableDict :: SerializableDict NoisyConf
dSerializableDict = SerializableDict


--TODO Can we auto-gen this whole section?
resourceDictNoisyPingCount :: Dict (Resource NoisyPingCount)
resourceDictServiceNoisy :: Dict (Resource (Service NoisyConf))
resourceDictServiceProcessNoisy :: Dict (Resource (ServiceProcess NoisyConf))
resourceDictConfigItemNoisy :: Dict (Resource NoisyConf)
resourceDictNoisyPingCount = Dict
resourceDictServiceNoisy = Dict
resourceDictServiceProcessNoisy = Dict
resourceDictConfigItemNoisy = Dict

relationDictHasPingCountServiceNoisyNoisyPingCount :: Dict (
    Relation HasPingCount (Service NoisyConf) NoisyPingCount
  )
relationDictSupportsClusterServiceNoisy :: Dict (
    Relation Supports Cluster (Service NoisyConf)
  )
relationDictHasNodeServiceProcessNoisy :: Dict (
    Relation Runs Node (ServiceProcess NoisyConf)
  )
relationDictWantsServiceProcessNoisyConfigItemNoisy :: Dict (
    Relation WantsConf (ServiceProcess NoisyConf) NoisyConf
  )
relationDictHasServiceProcessNoisyConfigItemNoisy :: Dict (
    Relation HasConf (ServiceProcess NoisyConf) NoisyConf
  )
relationDictInstanceOfServiceNoisyServiceProcessNoisy :: Dict (
    Relation InstanceOf (Service NoisyConf) (ServiceProcess NoisyConf)
  )
relationDictOwnsServiceProcessNoisyServiceName :: Dict (
    Relation Owns (ServiceProcess NoisyConf) ServiceName
  )
relationDictHasPingCountServiceNoisyNoisyPingCount = Dict
relationDictSupportsClusterServiceNoisy = Dict
relationDictHasNodeServiceProcessNoisy = Dict
relationDictWantsServiceProcessNoisyConfigItemNoisy = Dict
relationDictHasServiceProcessNoisyConfigItemNoisy = Dict
relationDictInstanceOfServiceNoisyServiceProcessNoisy = Dict
relationDictOwnsServiceProcessNoisyServiceName = Dict

remotable
  [ 'dConfigDict
  , 'dSerializableDict
  , 'resourceDictServiceNoisy
  , 'resourceDictServiceProcessNoisy
  , 'resourceDictConfigItemNoisy
  , 'resourceDictNoisyPingCount
  , 'relationDictSupportsClusterServiceNoisy
  , 'relationDictHasNodeServiceProcessNoisy
  , 'relationDictWantsServiceProcessNoisyConfigItemNoisy
  , 'relationDictHasServiceProcessNoisyConfigItemNoisy
  , 'relationDictInstanceOfServiceNoisyServiceProcessNoisy
  , 'relationDictOwnsServiceProcessNoisyServiceName
  , 'relationDictHasPingCountServiceNoisyNoisyPingCount
  ]

instance Resource (Service NoisyConf) where
  resourceDict = $(mkStatic 'resourceDictServiceNoisy)

instance Resource (ServiceProcess NoisyConf) where
  resourceDict = $(mkStatic 'resourceDictServiceProcessNoisy)

instance Resource NoisyConf where
  resourceDict = $(mkStatic 'resourceDictConfigItemNoisy)

instance Resource NoisyPingCount where
  resourceDict = $(mkStatic 'resourceDictNoisyPingCount)

instance Relation Supports Cluster (Service NoisyConf) where
  relationDict = $(mkStatic 'relationDictSupportsClusterServiceNoisy)

instance Relation Runs Node (ServiceProcess NoisyConf) where
  relationDict = $(mkStatic 'relationDictHasNodeServiceProcessNoisy)

instance Relation HasConf (ServiceProcess NoisyConf) NoisyConf where
  relationDict = $(mkStatic 'relationDictHasServiceProcessNoisyConfigItemNoisy)

instance Relation WantsConf (ServiceProcess NoisyConf) NoisyConf where
  relationDict = $(mkStatic 'relationDictWantsServiceProcessNoisyConfigItemNoisy)

instance Relation InstanceOf (Service NoisyConf) (ServiceProcess NoisyConf) where
  relationDict = $(mkStatic 'relationDictInstanceOfServiceNoisyServiceProcessNoisy)

instance Relation Owns (ServiceProcess NoisyConf) ServiceName where
  relationDict = $(mkStatic 'relationDictOwnsServiceProcessNoisyServiceName)

instance Relation HasPingCount (Service NoisyConf) NoisyPingCount where
  relationDict = $(mkStatic 'relationDictHasPingCountServiceNoisyNoisyPingCount)

--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

instance Configuration NoisyConf where
  schema = noisySchema
  sDict = $(mkStatic 'dSerializableDict)

-- | Block forever.
never :: Process ()
never = liftIO $ newEmptyMVar >>= takeMVar

remotableDecl [ [d|
  noisy :: Service NoisyConf
  noisy = Service
            (ServiceName "noisy")
            $(mkStaticClosure 'noisyProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'dConfigDict))

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
