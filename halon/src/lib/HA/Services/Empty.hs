-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Empty
  ( HA.Services.Empty.__remoteTable
  , emptyConfigDict
  , emptyConfigDict__static
  , emptySDict
  , emptySDict__static
  ) where

import HA.ResourceGraph
import HA.Resources
import HA.Service

import Control.Applicative (pure)
import Control.Distributed.Process.Closure
  ( SerializableDict(..)
  , mkStatic
  , remotable
  )

emptyConfigDict :: Dict (Configuration ())
emptyConfigDict = Dict

emptySDict :: SerializableDict ()
emptySDict = SerializableDict

--TODO Can we auto-gen this whole section?
resourceDictServiceEmpty :: Dict (Resource (Service ()))
resourceDictServiceProcessEmpty :: Dict (Resource (ServiceProcess ()))
resourceDictConfigItemEmpty :: Dict (Resource ())
resourceDictServiceEmpty = Dict
resourceDictServiceProcessEmpty = Dict
resourceDictConfigItemEmpty = Dict

relationDictSupportsClusterServiceEmpty :: Dict (
    Relation Supports Cluster (Service ())
  )
relationDictRunsNodeServiceProcessEmpty :: Dict (
    Relation Runs Node (ServiceProcess ())
  )
relationDictWantsServiceProcessEmptyConfigItemEmpty :: Dict (
    Relation WantsConf (ServiceProcess ()) ()
  )
relationDictHasServiceProcessEmptyConfigItemEmpty :: Dict (
    Relation HasConf (ServiceProcess ()) ()
  )
relationDictInstanceOfServiceEmptyServiceProcessEmpty :: Dict (
    Relation InstanceOf (Service ()) (ServiceProcess ())
  )
relationDictOwnsServiceProcessEmptyServiceName :: Dict (
    Relation Owns (ServiceProcess ()) ServiceName
  )

relationDictSupportsClusterServiceEmpty = Dict
relationDictRunsNodeServiceProcessEmpty = Dict
relationDictWantsServiceProcessEmptyConfigItemEmpty = Dict
relationDictHasServiceProcessEmptyConfigItemEmpty = Dict
relationDictInstanceOfServiceEmptyServiceProcessEmpty = Dict
relationDictOwnsServiceProcessEmptyServiceName = Dict

remotable
  [ 'emptyConfigDict
  , 'emptySDict
  , 'resourceDictServiceEmpty
  , 'resourceDictServiceProcessEmpty
  , 'resourceDictConfigItemEmpty
  , 'relationDictSupportsClusterServiceEmpty
  , 'relationDictRunsNodeServiceProcessEmpty
  , 'relationDictHasServiceProcessEmptyConfigItemEmpty
  , 'relationDictWantsServiceProcessEmptyConfigItemEmpty
  , 'relationDictInstanceOfServiceEmptyServiceProcessEmpty
  , 'relationDictOwnsServiceProcessEmptyServiceName
  ]

instance Resource (Service ()) where
  resourceDict = $(mkStatic 'resourceDictServiceEmpty)

instance Resource (ServiceProcess ()) where
  resourceDict = $(mkStatic 'resourceDictServiceProcessEmpty)

instance Resource () where
  resourceDict = $(mkStatic 'resourceDictConfigItemEmpty)

instance Relation Supports Cluster (Service ()) where
  relationDict = $(mkStatic 'relationDictSupportsClusterServiceEmpty)

instance Relation Runs Node (ServiceProcess ()) where
  relationDict = $(mkStatic 'relationDictRunsNodeServiceProcessEmpty)

instance Relation HasConf (ServiceProcess ()) () where
  relationDict = $(mkStatic 'relationDictHasServiceProcessEmptyConfigItemEmpty)

instance Relation WantsConf (ServiceProcess ()) () where
  relationDict = $(mkStatic 'relationDictWantsServiceProcessEmptyConfigItemEmpty)

instance Relation InstanceOf (Service ()) (ServiceProcess ()) where
  relationDict = $(mkStatic 'relationDictInstanceOfServiceEmptyServiceProcessEmpty)

instance Relation Owns (ServiceProcess ()) ServiceName where
  relationDict = $(mkStatic 'relationDictOwnsServiceProcessEmptyServiceName)

instance Configuration () where
  schema = pure ()
  sDict = $(mkStatic 'emptySDict)
