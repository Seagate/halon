{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}

-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Frontier
    ( FrontierConf(..)
    , frontier
    , frontierService
    , HA.Services.Frontier.__remoteTable
    , HA.Services.Frontier.__resourcesTable
    , HA.Services.Frontier.__remoteTableDecl
    , frontier__static
    , module HA.Services.Frontier.Interface
    ) where

import qualified Data.ByteString      as B
import           Data.Monoid ((<>))
import           Data.Typeable
import           Control.Monad (forever, void)
import           Control.Monad.Fix (fix)
import           GHC.Generics
import           System.IO

import Control.Distributed.Process hiding (finally, bracket)
import Control.Monad.Catch (finally, bracket)
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Data.Hashable
import Options.Schema
import Options.Schema.Builder
import Network hiding (Service)

import HA.Aeson
import HA.Debug
import HA.SafeCopy
import HA.Service hiding (configDict)
import HA.Service.TH
import HA.Services.Frontier.Command
import HA.Services.Frontier.Interface

data FrontierConf =
    FrontierConf { _fcPort :: Int }
    deriving (Eq, Generic, Show, Typeable)

type instance ServiceState FrontierConf = ProcessId

instance Hashable FrontierConf
instance ToJSON FrontierConf
deriveSafeCopy 0 'base ''FrontierConf

frontierSchema :: Schema FrontierConf
frontierSchema =
    let port = intOption
               $  long "port"
               <> short 'p'
               <> metavar "FRONTIER_PORT" in
    FrontierConf <$> port

storageIndex ''FrontierConf "b8ed9f06-3f81-4860-84ba-81d8e20d39c4"
serviceStorageIndex ''FrontierConf "67172603-0b38-4df4-b507-583894d71e4d"
$(generateDicts ''FrontierConf)
$(deriveService ''FrontierConf 'frontierSchema [])

createServerSocket :: Int -> Process Socket
createServerSocket port = liftIO $ listenOn (PortNumber $! fromIntegral port)

tcpServerLoop :: Socket -> Process ()
tcpServerLoop sock = forever $ do
    (h,_,_) <- liftIO $ accept sock
    self <- getSelfPid
    void $ spawnLocal $ do
      link self
      finally (dialog h) (cleanupHandle h)

dialog :: Handle -> Process ()
dialog h = loop
  where
    loop = hReadCommand h >>= \case
        CM r -> do
          sendRC interface r
          fix $ \go -> receiveWait
            [ receiveSvc interface $ \case
                FrontierChunk resp -> do
                  liftIO $ B.hPut h resp >> hFlush h
                  go
                FrontierDone -> return ()
            ]
          loop
        Quit -> return ()

cleanupHandle :: Handle -> Process ()
cleanupHandle h = liftIO $ hClose h

hReadCommand :: Handle -> Process Command
hReadCommand h = do
    ln <- liftIO $ B.hGetLine h
    pid <- getSelfPid
    case parseCommand ln pid of
      Just cmd -> return cmd
      _        -> hReadCommand h

frontierService :: FrontierConf -> Process ()
frontierService (FrontierConf port) =
  bracket (createServerSocket port)
          (liftIO . sClose)
          tcpServerLoop

remotableDecl [ [d|

    frontierFunctions :: ServiceFunctions FrontierConf
    frontierFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where
      bootstrap conf = do
        self <- getSelfPid
        pid <- spawnLocalName "service::frontier::process" $ do
          link self
          () <- expect
          frontierService conf
        return (Right pid)
      mainloop _ _ = return []
      teardown _ _ = return ()
      confirm  _ pid = usend pid ()

    frontier :: Service FrontierConf
    frontier = Service (ifServiceName interface)
               $(mkStaticClosure 'frontierFunctions)
               ($(mkStatic 'someConfigDict)
                 `staticApply` $(mkStatic 'configDictFrontierConf))
    |] ]

instance HasInterface FrontierConf where
  type ToSvc FrontierConf = FrontierReply
  type FromSvc FrontierConf = FrontierCmd
  getInterface _ = HA.Services.Frontier.Interface.interface
