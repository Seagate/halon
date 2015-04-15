{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Mero.Types where

import Control.Applicative
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Data.Binary (Binary)
import Data.Hashable (Hashable)

import HA.ResourceGraph
import HA.Service
import HA.Service.TH
import Mero.Notification (Set)
import Options.Schema

data MeroConf = MeroConf deriving (Eq, Generic, Show, Typeable)

instance Binary MeroConf
instance Hashable MeroConf

newtype TypedChannel a = TypedChannel (SendPort a)
    deriving (Eq, Show, Typeable, Binary, Hashable)

data MeroChannel = MeroChannel deriving (Eq, Show, Typeable, Generic)

instance Binary MeroChannel
instance Hashable MeroChannel

data DeclareMeroChannel =
    DeclareMeroChannel
    { dmcPid     :: !(ServiceProcess MeroConf)
    , dmcChannel :: !(TypedChannel Set)
    }
    deriving Typeable

instance Binary DeclareMeroChannel
instance Hashable DeclareMeroChannel

resourceDictMeroChannel :: Dict (Resource (TypedChannel Set))
resourceDictMeroChannel = Dict

relationDictMeroChanelServiceProcessChannel :: Dict (
    Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel Set)
  )
relationDictMeroChanelServiceProcessChannel = Dict

meroSchema :: Schema MeroConf
meroSchema = pure MeroConf

$(generateDicts ''MeroConf)
$(deriveService ''MeroConf 'meroSchema [ 'resourceDictMeroChannel
                                       , 'relationDictMeroChanelServiceProcessChannel
                                       ])

instance Resource (TypedChannel Set) where
    resourceDict = $(mkStatic 'resourceDictMeroChannel)

instance Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel Set) where
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessChannel)

meroServiceName :: ServiceName
meroServiceName = ServiceName "m0d"
