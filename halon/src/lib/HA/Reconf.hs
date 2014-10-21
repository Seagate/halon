-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Reconf is a process used to read configuration from some location and
-- send configuration updates to the recovery coordionator.

{-# LANGUAGE TemplateHaskell #-}
module HA.Reconf (
    GlobalOpts
  , globalSchema
  , reconf
) where

import HA.Service
import HA.Resources

import Control.Distributed.Process
import Control.Distributed.Process.Closure (mkStatic)
import Control.Distributed.Static
  ( staticApply )

import Data.Binary (Binary)
import Data.Monoid
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema
import Options.Schema.Builder

-- Schemata
import HA.NodeAgent (NodeAgentConf, naConfigDict, naConfigDict__static)

-- Global options
data GlobalOpts = GlobalOpts
    NodeAgentConf
  deriving (Typeable, Generic)

instance Binary GlobalOpts

nodeAgentConf :: Option NodeAgentConf
nodeAgentConf = compositeOption schema
              $ long "nodeAgent"
              <> long "na"
              <> summary "Node Agent configuration."
              <> detail "DEPRECATED"

globalSchema :: Schema GlobalOpts
globalSchema = GlobalOpts
             <$$> one nodeAgentConf

-- | Send new configuration messages to the recovery co-ordinator.
reconf :: (GlobalOpts, ConfigurationFilter, ProcessId)
       -> Process ()
reconf ((GlobalOpts nac), fltr, rc) = do
  self <- getSelfPid
  send rc $ EpochRequest self
  _ <- receiveTimeout 5000000 [
      match $ \(EpochResponse epoch) ->
              spawnLocal $ reconfService nac
                          ($(mkStatic 'someConfigDict)
                            `staticApply` $(mkStatic 'naConfigDict))
                          fltr epoch rc
    ]
  return ()

reconfService :: (Generic a, Typeable a, Configuration a)
              => a
              -> Static (SomeConfigDict)
              -> ConfigurationFilter
              -> EpochId
              -> ProcessId
              -> Process ()
reconfService opts cd fltr epoch rc =
  send rc . encodeP $ ConfigurationUpdate epoch opts cd fltr