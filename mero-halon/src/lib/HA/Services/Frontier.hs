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
import Data.Aeson
import Data.Binary
import Data.Hashable
import Options.Schema
import Options.Schema.Builder
import Network hiding (Service)

import HA.EventQueue.Producer (promulgate)
import HA.Service hiding (configDict)
import HA.Service.TH
import HA.Services.Frontier.Command

data FrontierConf =
    FrontierConf { _fcPort :: Int }
    deriving (Eq, Generic, Show, Typeable)

instance Binary FrontierConf
instance Hashable FrontierConf
instance ToJSON FrontierConf

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
          self <- getSelfPid
          _ <- promulgate (r, self)
          fix $ \go -> receiveWait
            [ match $ \resp -> do
                liftIO $ B.hPut h resp >> hFlush h
                go
            , match return
            ] :: Process ()
          loop
        CR r -> do
          self <- getSelfPid
          _ <- promulgate (r, self)
          fix $ \go -> receiveWait
            [ match $ \resp -> do
                liftIO $ B.hPut h resp >> hFlush h
                go
            , match return
            ] :: Process ()
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
    frontierService (FrontierConf port) =
      bracket (createServerSocket port)
              (liftIO . sClose)
              tcpServerLoop

    frontier :: Service FrontierConf
    frontier = Service "frontier"
               $(mkStaticClosure 'frontierService)
               ($(mkStatic 'someConfigDict)
                 `staticApply` $(mkStatic 'configDictFrontierConf))
    |] ]
