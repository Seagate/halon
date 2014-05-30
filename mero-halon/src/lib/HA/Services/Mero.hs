-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Mero (m0d, HA.Services.Mero.__remoteTableDecl) where

import HA.NodeAgent
import HA.NodeAgent.Lookup (nodeAgentLabel)
import HA.EventQueue.Producer (promulgate)
import HA.Resources
import qualified Mero.Notification
import Control.Distributed.Process.Closure (remotableDecl, mkStaticClosure)
import System.Process
import Control.Distributed.Process
import System.IO
import System.Directory (doesFileExist, removeFile)
import Control.Monad (forever, unless, when, void)
import Control.Concurrent (threadDelay)
import Mero.Epoch (sendEpochBlocking)
import Mero.Messages
import HA.Network.Address
import Data.ByteString (ByteString)

updateEpoch :: EpochId -> Process EpochId
updateEpoch epoch =
   do network <- liftIO readNetworkGlobalIVar
      let Just addr = parseAddress "0@lo:12345:34:100"
      mnewepoch <- liftIO $ sendEpochBlocking network addr epoch 5
      case mnewepoch of
        Just newepoch ->
          do say $ "Updated epoch to "++show epoch
             return newepoch
        Nothing -> return 0

remotableDecl [ [d|
    m0d :: Service
    m0d = service "m0d" $(mkStaticClosure 'm0dProcess)

    m0dProcess :: Process ()
    m0dProcess = do
        say $ "Starting service m0d"
        self <- getSelfPid
        bracket
    --      (liftIO $ createProcess $ proc "mero_call" ["m0d"])
          (liftIO $ createProcess $ proc "cat" [])
          (\(_, _, _, h_m0d) -> liftIO $ terminateAndWait h_m0d) $
          \_ -> bracket_ Mero.Notification.initialize Mero.Notification.finalize $ do
            -- give m0d a chance to fire up
            liftIO $ threadDelay 10000000
            bracket
              -- (liftIO $ createProcess $ (proc "mero_call" ["m0ctl"]) { std_out = CreatePipe })
              (liftIO $ createProcess $ (proc "cat" []) { std_out = CreatePipe })
              (\(_, _, _, h_m0ctl) -> liftIO $ terminateAndWait h_m0ctl) $
              \(_, Just out, _, h_m0ctl) -> do
                _ <- spawnLinked $ dummyStripingMonitor
                _ <- spawnLinked $ m0ctlMonitor self out h_m0ctl
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
        dummyStripingMonitor = forever $ do
            let dummyFile = "dummy-striping-error"
            liftIO $ threadDelay 1000000
            exists <- liftIO $ doesFileExist dummyFile
            when exists $ do
              liftIO $ removeFile dummyFile
              mbpid <- whereis nodeAgentLabel
              case mbpid of
                Nothing -> error "NodeAgent is not registered."
                Just na -> promulgate (StripingError (Node na))

        m0ctlMonitor srv out h_m0ctl = loop [] where
          loop buf = do
            let cleanup = do
                    unless (null buf) $ send srv (reverse buf)
                    send srv ()
            exited <- liftIO $ getProcessExitCode h_m0ctl
            case exited of
              Just _ -> cleanup
              _ -> do line <- liftIO (hGetLine out) `onException` cleanup
                      case (head line=='-', null buf) of
                        (True,False) -> send srv (reverse buf) >> loop []
                        (True,True) -> loop []
                        (_,_) -> loop (line:buf)

        go epoch = do
            let shutdownAndTellThem = do
                  mbpid <- whereis nodeAgentLabel
                  case mbpid of
                      Nothing -> error "NodeAgent is not registered."
                      Just na -> expire $ ServiceFailed (Node na) m0d -- XXX
            receiveWait $
              [ match $ \(EpochTransition epochExpected epochTarget state) -> do
                  let _ = say $ "Service wrapper got new equation: " ++ show (state::ByteString)
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
