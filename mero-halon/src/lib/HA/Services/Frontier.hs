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

import           Prelude hiding ((<$>))
import           Control.Applicative ((<$>))
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
import HA.Service hiding (configDict)
import HA.Service.TH
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

$(generateDicts ''FrontierConf)
$(deriveService ''FrontierConf 'frontierSchema [])

createServerSocket :: Int -> Process Socket
createServerSocket port = liftIO $ listenOn (PortNumber $ fromIntegral port)

tcpServerLoop :: ProcessId -> Socket -> Process ()
tcpServerLoop mmid sock = do
    (h,_,_) <- liftIO $ accept sock
    _       <- spawnLocal $ finally (dialog mmid h) (cleanupHandle h)
    tcpServerLoop mmid sock

dialog :: ProcessId -> Handle -> Process ()
dialog mmid h = loop
  where
    loop = hReadCommand h >>= \case
        MultimapGetKeyValuePairs -> do
          mkv <- getKeyValuePairs mmid
          let resp = respond (ServeMultimapKeyValues mkv)
          liftIO $ do
            BL.hPut h resp
            hFlush h
          loop
        ReadResourceGraph -> do
          rg <- getGraph mmid
          let resp = respond (ServeResources $ getGraphResources rg)
          liftIO $ do
            BL.hPut h resp
            hFlush h
          loop
        Quit -> return ()

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
                 `staticApply` $(mkStatic 'configDictFrontierConf))
    |] ]
