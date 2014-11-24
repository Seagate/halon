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

import HA.Service
import HA.NodeAgent
import HA.ResourceGraph
import HA.Resources (Node)

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
resourceDictConfigItemDummy :: Dict (Resource DummyConf)
resourceDictServiceDummy = Dict
resourceDictConfigItemDummy = Dict

relationDictHasNodeServiceDummy :: Dict (Relation Runs Node (Service DummyConf))
relationDictWantsServiceDummyConfigItemDummy ::
  Dict (Relation WantsConf (Service DummyConf) DummyConf)
relationDictHasServiceDummyConfigItemDummy ::
  Dict (Relation HasConf (Service DummyConf) DummyConf)
relationDictHasNodeServiceDummy = Dict
relationDictWantsServiceDummyConfigItemDummy = Dict
relationDictHasServiceDummyConfigItemDummy = Dict

remotable
  [ 'dConfigDict
  , 'dSerializableDict
  , 'resourceDictServiceDummy
  , 'resourceDictConfigItemDummy
  , 'relationDictHasNodeServiceDummy
  , 'relationDictHasServiceDummyConfigItemDummy
  , 'relationDictWantsServiceDummyConfigItemDummy
  ]

instance Resource (Service DummyConf) where
  resourceDict = $(mkStatic 'resourceDictServiceDummy)

instance Resource DummyConf where
  resourceDict = $(mkStatic 'resourceDictConfigItemDummy)

instance Relation Runs Node (Service DummyConf) where
  relationDict = $(mkStatic 'relationDictHasNodeServiceDummy)

instance Relation HasConf (Service DummyConf) DummyConf where
  relationDict = $(mkStatic 'relationDictHasServiceDummyConfigItemDummy)

instance Relation WantsConf (Service DummyConf) DummyConf where
  relationDict = $(mkStatic 'relationDictWantsServiceDummyConfigItemDummy)

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
  dummy = service
            dSerializableDict
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'dConfigDict))
            $(mkStatic 'dSerializableDict)
            "dummy"
            $(mkStaticClosure 'dummyProcess)

  dummyProcess :: DummyConf -> Process ()
  dummyProcess (DummyConf hw) = (`catchExit` onExit) $ do
      say $ "Starting service dummy"
      say . fromDefault $ hw
      never
    where
      onExit _ Shutdown = say $ "DummyService stopped."
      onExit _ Reconfigure = say $ "DummyService reconfigured."

  |] ]
