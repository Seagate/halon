-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Dummy
  ( dummy
  , DummyConf(..)
  , HA.Services.Dummy.__remoteTable
  , HA.Services.Dummy.__remoteTableDecl
  ) where

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

import Data.Binary (Binary)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

newtype DummyConf = DummyConf {
  helloWorld :: Defaultable String
} deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

dummySchema :: Schema DummyConf
dummySchema = let
    hw = defaultable "Hello World!" . strOption $ long "helloWorld"
                <> short 'm'
                <> metavar "GREETING"
  in DummyConf <$> hw

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

dConfigDict :: Dict (Configuration DummyConf)
dConfigDict = Dict

dSerializableDict :: SerializableDict DummyConf
dSerializableDict = SerializableDict

--TODO Can we auto-gen this whole section?
resourceDictServiceDummy :: Dict (Resource (Service DummyConf))
resourceDictServiceProcessDummy :: Dict (Resource (ServiceProcess DummyConf))
resourceDictConfigItemDummy :: Dict (Resource DummyConf)
resourceDictServiceDummy = Dict
resourceDictServiceProcessDummy = Dict
resourceDictConfigItemDummy = Dict

relationDictSupportsClusterServiceDummy :: Dict (
    Relation Supports Cluster (Service DummyConf)
  )
relationDictHasNodeServiceProcessDummy :: Dict (
    Relation Runs Node (ServiceProcess DummyConf)
  )
relationDictWantsServiceProcessDummyConfigItemDummy :: Dict (
    Relation WantsConf (ServiceProcess DummyConf) DummyConf
  )
relationDictHasServiceProcessDummyConfigItemDummy :: Dict (
    Relation HasConf (ServiceProcess DummyConf) DummyConf
  )
relationDictInstanceOfServiceDummyServiceProcessDummy :: Dict (
    Relation InstanceOf (Service DummyConf) (ServiceProcess DummyConf)
  )
relationDictOwnsServiceProcessDummyServiceName :: Dict (
    Relation Owns (ServiceProcess DummyConf) ServiceName
  )
relationDictSupportsClusterServiceDummy = Dict
relationDictHasNodeServiceProcessDummy = Dict
relationDictWantsServiceProcessDummyConfigItemDummy = Dict
relationDictHasServiceProcessDummyConfigItemDummy = Dict
relationDictInstanceOfServiceDummyServiceProcessDummy = Dict
relationDictOwnsServiceProcessDummyServiceName = Dict

remotable
  [ 'dConfigDict
  , 'dSerializableDict
  , 'resourceDictServiceDummy
  , 'resourceDictServiceProcessDummy
  , 'resourceDictConfigItemDummy
  , 'relationDictSupportsClusterServiceDummy
  , 'relationDictHasNodeServiceProcessDummy
  , 'relationDictWantsServiceProcessDummyConfigItemDummy
  , 'relationDictHasServiceProcessDummyConfigItemDummy
  , 'relationDictInstanceOfServiceDummyServiceProcessDummy
  , 'relationDictOwnsServiceProcessDummyServiceName
  ]

instance Resource (Service DummyConf) where
  resourceDict = $(mkStatic 'resourceDictServiceDummy)

instance Resource (ServiceProcess DummyConf) where
  resourceDict = $(mkStatic 'resourceDictServiceProcessDummy)

instance Resource DummyConf where
  resourceDict = $(mkStatic 'resourceDictConfigItemDummy)

instance Relation Supports Cluster (Service DummyConf) where
  relationDict = $(mkStatic 'relationDictSupportsClusterServiceDummy)

instance Relation Runs Node (ServiceProcess DummyConf) where
  relationDict = $(mkStatic 'relationDictHasNodeServiceProcessDummy)

instance Relation HasConf (ServiceProcess DummyConf) DummyConf where
  relationDict = $(mkStatic 'relationDictHasServiceProcessDummyConfigItemDummy)

instance Relation WantsConf (ServiceProcess DummyConf) DummyConf where
  relationDict = $(mkStatic 'relationDictWantsServiceProcessDummyConfigItemDummy)

instance Relation InstanceOf (Service DummyConf) (ServiceProcess DummyConf) where
  relationDict = $(mkStatic 'relationDictInstanceOfServiceDummyServiceProcessDummy)

instance Relation Owns (ServiceProcess DummyConf) ServiceName where
  relationDict = $(mkStatic 'relationDictOwnsServiceProcessDummyServiceName)
--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

instance Configuration DummyConf where
  schema = dummySchema
  sDict = $(mkStatic 'dSerializableDict)

-- | Block forever.
never :: Process ()
never = liftIO $ newEmptyMVar >>= takeMVar

remotableDecl [ [d|
  dummy :: Service DummyConf
  dummy = Service
            (ServiceName "dummy")
            $(mkStaticClosure 'dummyProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'dConfigDict))

  dummyProcess :: DummyConf -> Process ()
  dummyProcess (DummyConf hw) = (`catchExit` onExit) $ do
      say $ "Starting service dummy"
      say . fromDefault $ hw
      never
    where
      onExit _ Shutdown = say $ "DummyService stopped."
      onExit _ Reconfigure = say $ "DummyService reconfigured."

  |] ]
