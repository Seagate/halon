-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
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
    , notifyMero
    ) where

import HA.EventQueue.Producer (expiate, promulgate)
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Service
import HA.Resources
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState)
import HA.Service
import HA.Services.Mero.CEP (meroRulesF)
import HA.Services.Mero.Types
import qualified HA.ResourceGraph as G

import Mero.Epoch (sendEpochBlocking)
import qualified Mero.Notification
import Mero.Notification.HAState (Note(..))

import Network.CEP
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
import Data.Maybe (listToMaybe)

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
        (Mero.Notification.initialize haAddr)
        (\_ -> Mero.Notification.finalize) $
        \ep -> do
          c <- spawnChannelLocal $ statusProcess ep m0addr self
          sendMeroChannel c
          say $ "Starting service m0d"
          go ep 0
    where
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


-- | Combine @ConfObj@s and a @ConfObjectState@ into a 'Set' and
-- send it to every mero service running on the cluster.
notifyMero :: [M0.AnyConfObj] -- ^ List of resources (instance of @ConfObj@)
           -> ConfObjectState
           -> PhaseM LoopState l ()
notifyMero cs st = do
  pids <- findRunningServiceProcesses m0d
  phaseLog "action" "Sending configuration update to mero services"
  rg <- getLocalGraph
  mapM_ (sendSetEvent rg) pids
  where
    getFid (M0.AnyConfObj a) = M0.fid a

    setEvent :: Mero.Notification.Set
    setEvent = Mero.Notification.Set $ map (flip Note st . getFid) cs

    sendSetEvent rg p = do
      liftProcess $ case listToMaybe $ G.connectedTo p MeroChannel rg of
        Just (TypedChannel chan) -> sendChan chan setEvent
        _ -> say $
          "HA.Services.Mero.notifyMero: Cannot find MeroChanel for " ++ show p
