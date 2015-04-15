-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
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
    ) where

import HA.EventQueue.Producer (expiate, promulgate)
import HA.RecoveryCoordinator.Mero (LoopState)
import HA.ResourceGraph hiding (null)
import HA.Resources
import HA.Service
import HA.Service.TH
import HA.Services.Empty
import HA.Services.Mero.Types
import qualified Mero.Notification
import Control.Distributed.Process.Closure
  (
    remotableDecl
  , mkStatic
  , mkStaticClosure
  )
import Control.Applicative
import Control.Distributed.Static
  ( staticApply )
import System.Process
import Control.Distributed.Process hiding (send)
import System.IO
import System.Directory (doesFileExist, removeFile)
import Control.Monad (forever, unless, when, void)
import Control.Concurrent (threadDelay)
-- XXX We probably want USE_MERO here, rather than USE_RPC.
#ifdef USE_RPC
import Mero.Epoch (sendEpochBlocking)
import qualified Network.Transport.RPC as RPC
#endif
import Mero.Messages
import Network.CEP (RuleM)
import Data.ByteString (ByteString)

updateEpoch :: EpochId -> Process EpochId
-- XXX We probably want USE_MERO here, rather than USE_RPC.
#ifdef USE_RPC
updateEpoch epoch = do
    mnewepoch <- liftIO $ sendEpochBlocking (RPC.rpcAddress "0@lo:12345:34:100") epoch 5
    case mnewepoch of
      Just newepoch ->
        do say $ "Updated epoch to "++show epoch
           return newepoch
      Nothing -> return 0
#else
updateEpoch _ = error "updateEpoch: RPC support required."
#endif

sendMeroChannel :: Process ()
sendMeroChannel = do
    c   <- spawnChannelLocal statusProcess
    pid <- getSelfPid
    let chan = DeclareMeroChannel (ServiceProcess pid) (TypedChannel c)
    promulgate chan

statusProcess :: ReceivePort Mero.Notification.Set -> Process ()
statusProcess _ = return ()

meroRules :: RuleM LoopState ()
meroRules = meroRulesF m0d

remotableDecl [ [d|

    m0d :: Service MeroConf
    m0d = Service
            meroServiceName
            $(mkStaticClosure 'm0dProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictMeroConf))

    m0dProcess :: MeroConf -> Process ()
    m0dProcess _ = do
        say $ "Starting service m0d"
        self <- getSelfPid
        bracket
          (liftIO $ createProcess $ proc "mero_call" ["m0d"])
          (\(_, _, _, h_m0d) -> liftIO $ terminateAndWait h_m0d) $
          \_ -> bracket_ Mero.Notification.initialize Mero.Notification.finalize $ do
            -- give m0d a chance to fire up
            liftIO $ threadDelay 10000000
            bracket
              (liftIO $ createProcess $ (proc "mero_call" ["m0ctl"]) { std_out = CreatePipe })
              (\(_, _, _, h_m0ctl) -> liftIO $ terminateAndWait h_m0ctl) $
              \(_, Just out, _, h_m0ctl) -> do
                sendMeroChannel
                go 0

      where
        spawnLinked p = do
            self <- getSelfPid
            spawnLocal $ do
              link self
              p
        terminateAndWait h = do
            terminateProcess h
            void $ waitForProcess h

        go epoch = do
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
                             go epoch
                     else do updatedEpoch <- updateEpoch epochTarget
                             -- if new epoch is rejected, die
                             when (updatedEpoch < epochTarget) $ shutdownAndTellThem
                             go updatedEpoch
              , match $ \buf ->
                  case examine buf of
                     True -> go epoch
                     False -> shutdownAndTellThem
              , match $ \() ->
                  shutdownAndTellThem
              ]
              ++ Mero.Notification.matchSet (go epoch)

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
