-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE TemplateHaskell       #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Mero
    ( MeroChannel(..)
    , TypedChannel(..)
    , m0d
    , HA.Services.Mero.__remoteTableDecl
    , HA.Services.Mero.Types.__remoteTable
    , m0dProcess__sdict
    , m0dProcess__tdict
    , m0d__static
    , meroRules
    , MeroConf(..)
    ) where

import HA.EventQueue.Producer (expiate, promulgate)
import HA.RecoveryCoordinator.Mero (LoopState)
import HA.Resources
import HA.Service
import HA.Services.Mero.CEP (meroRulesF)
import HA.Services.Mero.Types

import Mero.Epoch (sendEpochBlocking)
import qualified Mero.Notification

import qualified Network.RPC.RPCLite as RPC

import Control.Distributed.Process.Closure
  (
    remotableDecl
  , mkStatic
  , mkStaticClosure
  )
import Control.Distributed.Static
  ( staticApply )
import Control.Distributed.Process hiding (send)
import Control.Monad (forever, when, void)

import Data.ByteString (ByteString)
import Data.Defaultable (fromDefault)

import Network.CEP (Definitions)

updateEpoch :: RPC.ServerEndpoint
            -> RPC.RPCAddress
            -> EpochId -> Process EpochId
updateEpoch ep m0addr epoch = do
  mnewepoch <- liftIO $ sendEpochBlocking ep m0addr epoch 5
  case mnewepoch of
    Just newepoch ->
      do say $ "Updated epoch to "++show epoch
         return newepoch
    Nothing -> return 0

sendMeroChannel :: SendPort Mero.Notification.Set -> Process ()
sendMeroChannel c = do
  pid <- getSelfPid
  let chan = DeclareMeroChannel (ServiceProcess pid) (TypedChannel c)
  void $ promulgate chan

statusProcess :: RPC.ServerEndpoint
              -> RPC.RPCAddress
              -> ProcessId
              -> ReceivePort Mero.Notification.Set
              -> Process ()
statusProcess ep m0addr pid rp = link pid >> (forever $ do
    set <- receiveChan rp
    Mero.Notification.notifyMero ep m0addr set
  )

remotableDecl [ [d|

  m0d :: Service MeroConf
  m0d = Service
          meroServiceName
          $(mkStaticClosure 'm0dProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictMeroConf))

  m0dProcess :: MeroConf -> Process ()
  m0dProcess MeroConf{..} = do
      self <- getSelfPid
      bracket
        (Mero.Notification.initialize fp haAddr)
        (\_ -> Mero.Notification.finalize) $
        \ep -> do
          c <- spawnChannelLocal $ statusProcess ep m0addr self
          sendMeroChannel c
          say $ "Starting service m0d"
          go ep 0
    where
      fp = fromDefault mcPersistencePath
      haAddr = RPC.rpcAddress mcServerAddr
      m0addr = RPC.rpcAddress mcMeroAddr
      go ep epoch = do
          let shutdownAndTellThem = do
                node <- getSelfNode
                pid  <- getSelfPid
                expiate . encodeP $ ServiceFailed (Node node) m0d pid -- XXX
          receiveWait $
            [ match $ \(EpochTransition epochExpected epochTarget state) -> do
                say $ "Service wrapper got new equation: " ++ show (state::ByteString)
                wrapperPid <- getSelfPid
                if epoch < epochExpected
                   then do promulgate $ EpochTransitionRequest wrapperPid epoch epochTarget
                           go ep epoch
                   else do updatedEpoch <- updateEpoch ep m0addr epochTarget
                           -- if new epoch is rejected, die
                           when (updatedEpoch < epochTarget) $ shutdownAndTellThem
                           go ep updatedEpoch
            , match $ \buf ->
                case examine buf of
                   True -> go ep epoch
                   False -> shutdownAndTellThem
            , match $ \() ->
                shutdownAndTellThem
            ]

      -- In lieu of properly parsing the YAML output,
      -- we just aply a simple heuristic. This may or
      -- may not be adequate in the long term. Returns
      -- true if okay, false otherwise.
      examine :: [String] -> Bool
      examine xs = not $ or $ map hasError xs
         where
           hasError line =
              let w = words line
               in if length w > 0
                     then head w == "error:" ||
                          last w == "FAILED"
                     else False
    |] ]

meroRules :: Definitions LoopState ()
meroRules = meroRulesF m0d
