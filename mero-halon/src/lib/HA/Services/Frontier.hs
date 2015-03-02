{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Frontier
    ( FrontierConf(..)
    , frontier
    , frontierService
    , HA.Services.Frontier.__remoteTable
    , HA.Services.Frontier.__remoteTableDecl
    , frontierService__sdict
    , frontierService__tdict
    , frontier__static
    ) where

import           Control.Applicative ((<$>))
import           Control.Monad
import qualified Data.ByteString      as B
import qualified Data.ByteString.Lazy as BL
import           Data.Monoid ((<>))
import           Data.Typeable
import           GHC.Generics
import           System.IO

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Data.Binary
import Data.Hashable
import Options.Schema
import Options.Schema.Builder
import Network hiding (Service)

import HA.EventQueue.Producer (promulgate)
import HA.Multimap
import HA.RecoveryCoordinator.Mero
import HA.ResourceGraph
import HA.Resources
import HA.Service hiding (configDict)
import HA.Services.Frontier.Command

data FrontierConf =
    FrontierConf { _fcPort :: Int }
    deriving (Eq, Generic, Show, Typeable)

instance Binary FrontierConf
instance Hashable FrontierConf

frontierSchema :: Schema FrontierConf
frontierSchema =
    let port = intOption
               $  long "port"
               <> short 'p'
               <> metavar "FRONTIER_PORT" in
    FrontierConf <$> port

configDict :: Dict (Configuration FrontierConf)
configDict = Dict

serializableDict :: SerializableDict FrontierConf
serializableDict = SerializableDict

resourceDictService :: Dict (Resource (Service FrontierConf))
resourceDictService = Dict

resourceDictServiceProcess :: Dict (Resource (ServiceProcess FrontierConf))
resourceDictServiceProcess = Dict

relationDictHasServiceProcessConfigItem :: Dict (
    Relation HasConf (ServiceProcess FrontierConf) FrontierConf
    )
relationDictHasServiceProcessConfigItem = Dict

relationDictWantsServiceProcessConfigItem :: Dict (
    Relation WantsConf (ServiceProcess FrontierConf) FrontierConf
    )
relationDictWantsServiceProcessConfigItem = Dict

relationDictHasNodeServiceProcess :: Dict (
    Relation Runs Node (ServiceProcess FrontierConf)
    )
relationDictHasNodeServiceProcess = Dict

relationDictInstanceOfServiceServiceProcess :: Dict (
    Relation InstanceOf (Service FrontierConf) (ServiceProcess FrontierConf)
    )
relationDictInstanceOfServiceServiceProcess = Dict

relationDictOwnsServiceProcessServiceName :: Dict (
    Relation Owns (ServiceProcess FrontierConf) ServiceName
    )
relationDictOwnsServiceProcessServiceName = Dict

relationDictSupportsClusterService :: Dict (
    Relation Supports Cluster (Service FrontierConf)
    )
relationDictSupportsClusterService = Dict

resourceDictConfigItem :: Dict (Resource FrontierConf)
resourceDictConfigItem = Dict

remotable [ 'configDict
          , 'resourceDictConfigItem
          , 'serializableDict
          , 'resourceDictService
          , 'resourceDictServiceProcess
          , 'relationDictHasServiceProcessConfigItem
          , 'relationDictWantsServiceProcessConfigItem
          , 'relationDictHasNodeServiceProcess
          , 'relationDictInstanceOfServiceServiceProcess
          , 'relationDictOwnsServiceProcessServiceName
          , 'relationDictSupportsClusterService
          ]

instance Resource FrontierConf where
    resourceDict = $(mkStatic 'resourceDictConfigItem)

instance Resource (Service FrontierConf) where
    resourceDict = $(mkStatic 'resourceDictService)

instance Resource (ServiceProcess FrontierConf) where
    resourceDict = $(mkStatic 'resourceDictServiceProcess)

instance Relation HasConf (ServiceProcess FrontierConf) FrontierConf where
    relationDict = $(mkStatic 'relationDictHasServiceProcessConfigItem)

instance Relation WantsConf (ServiceProcess FrontierConf) FrontierConf where
    relationDict = $(mkStatic 'relationDictWantsServiceProcessConfigItem)

instance Relation Runs Node (ServiceProcess FrontierConf) where
    relationDict = $(mkStatic 'relationDictHasNodeServiceProcess)

instance Relation InstanceOf (Service FrontierConf) (ServiceProcess FrontierConf) where
    relationDict = $(mkStatic 'relationDictInstanceOfServiceServiceProcess)

instance Relation Owns (ServiceProcess FrontierConf) ServiceName where
    relationDict = $(mkStatic 'relationDictOwnsServiceProcessServiceName)

instance Relation Supports Cluster (Service FrontierConf) where
    relationDict = $(mkStatic 'relationDictSupportsClusterService)

instance Configuration FrontierConf where
    schema = frontierSchema
    sDict  = $(mkStatic 'serializableDict)

createServerSocket :: Int -> Process Socket
createServerSocket port = liftIO $ listenOn (PortNumber $ fromIntegral port)

tcpServerLoop :: ProcessId -> Socket -> Process ()
tcpServerLoop mmid sock = do
    (h,_,_) <- liftIO $ accept sock
    _       <- spawnLocal $ finally (dialog mmid h) (cleanupHandle h)
    tcpServerLoop mmid sock

dialog :: ProcessId -> Handle -> Process ()
dialog mmid h = forever $ do
    cmd <- hReadCommand h
    case cmd of
      MultimapGetKeyValuePairs -> do
        mkv <- getKeyValuePairs mmid
        let resp = respond (ServeMultimapKeyValues mkv)
        liftIO $ do
          BL.hPut h resp
          hFlush h
      ReadResourceGraph -> do
        rg <- getGraph mmid
        let resp = respond (ServeResources $ getGraphResources rg)
        liftIO $ do
          BL.hPut h resp
          hFlush h
      Quit -> error "Client issued QUIT command"

cleanupHandle :: Handle -> Process ()
cleanupHandle h = liftIO $ hClose h

hReadCommand :: Handle -> Process Command
hReadCommand h = do
    ln <- liftIO $ B.hGetLine h
    case parseCommand ln of
      Just cmd -> return cmd
      _        -> hReadCommand h

remotableDecl [ [d|
    frontierService :: FrontierConf -> Process ()
    frontierService (FrontierConf port) = do
      sock <- createServerSocket port
      self <- getSelfPid
      _    <- promulgate (GetMultimapProcessId self)
      mmid <- expect
      tcpServerLoop mmid sock

    frontier :: Service FrontierConf
    frontier = Service
               (ServiceName "frontier")
               $(mkStaticClosure 'frontierService)
               ($(mkStatic 'someConfigDict)
                 `staticApply` $(mkStatic 'configDict))
    |] ]
