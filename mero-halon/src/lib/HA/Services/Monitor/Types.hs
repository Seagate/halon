{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Monitor.Types where

import Data.Typeable
import GHC.Generics

import Control.Distributed.Process
import Data.Binary
import Data.Hashable
import Options.Schema

import HA.Service
import HA.Service.TH

data MonitorConf = MonitorConf deriving (Eq, Generic, Show, Typeable)

instance Binary MonitorConf
instance Hashable MonitorConf

monitorSchema :: Schema MonitorConf
monitorSchema = pure MonitorConf

monitorServiceName :: ServiceName
monitorServiceName = ServiceName "monitor"

$(generateDicts ''MonitorConf)
$(deriveService ''MonitorConf 'monitorSchema [])

data Monitor = Monitor deriving (Typeable, Generic)

instance Binary Monitor

data MonitorReply = MonitorReply ProcessId deriving (Typeable, Generic)

instance Binary MonitorReply
