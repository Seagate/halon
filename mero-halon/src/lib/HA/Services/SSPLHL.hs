-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Services.SSPLHL where

import Prelude hiding ((<$>), (<*>))
import HA.EventQueue.Producer (promulgate)
import HA.NodeAgent.Messages
import HA.Service
import HA.Service.TH
import qualified HA.Services.SSPL.Rabbit as Rabbit
import HA.Services.SSPL.HL.Resources


import Control.Applicative ((<$>), (<*>))

import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , ProcessMonitorNotification(..)
  , catchExit
  , match
  , monitor
  , receiveWait
  , say
  , spawnLocal
  , unmonitor
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad.State.Strict hiding (mapM_)

import Data.Binary (Binary)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.AMQP

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

import Prelude hiding (id, mapM_)

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

commandSchema :: Schema Rabbit.BindConf
commandSchema = let
    en = defaultable "sspl_hl_cmd" . strOption
        $ long "dcs_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_hl_cmd" . strOption
          $ long "dcs_routingKey"
          <> metavar "ROUTING_KEY"
    qn = defaultable "sspl_hl_cmd" . strOption
          $ long "dcs_queue"
          <> metavar "QUEUE_NAME"
  in Rabbit.BindConf <$> en <*> rk <*> qn

data SSPLHLConf = SSPLHLConf {
    scConnectionConf :: Rabbit.ConnectionConf
  , scCommandConf :: Rabbit.BindConf
} deriving (Eq, Generic, Show, Typeable)

instance Binary SSPLHLConf
instance Hashable SSPLHLConf

ssplhlSchema :: Schema SSPLHLConf
ssplhlSchema = SSPLHLConf <$> Rabbit.connectionSchema <*> commandSchema

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(generateDicts ''SSPLHLConf)
$(deriveService ''SSPLHLConf 'ssplhlSchema [])

--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

remotableDecl [ [d|

  ssplProcess :: SSPLHLConf -> Process ()
  ssplProcess (SSPLHLConf{..}) = let

      onExit _ Shutdown = say $ "SSPLHLService stopped."
      onExit _ Reconfigure = say $ "SSPLHLService stopping for reconfiguration."

      connectRetry lock = do
        pid <- spawnLocal $ connectSSPL lock
        mref <- monitor pid
        receiveWait [
            match $ \(ProcessMonitorNotification _ _ r) -> do
              say $ "SSPL Process died:\n\t" ++ show r
              connectRetry lock
          , match $ \() -> unmonitor mref >> (liftIO $ putMVar lock ())
          ]
      connectSSPL lock = do
        conn <- liftIO $ Rabbit.openConnection scConnectionConf
        chan <- liftIO $ openChannel conn
        Rabbit.receive chan scCommandConf (\msg -> void . promulgate
                                                    $ SSPLHLCmd (msgBody msg))
        () <- liftIO $ takeMVar lock
        liftIO $ closeConnection conn
        say "Connection closed."

    in (`catchExit` onExit) $ do
      say $ "Starting service sspl-hl"
      lock <- liftIO newEmptyMVar
      connectRetry lock

  sspl :: Service SSPLHLConf
  sspl = Service
          (ServiceName "sspl-hl")
          $(mkStaticClosure 'ssplProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictSSPLHLConf))

  |] ]
