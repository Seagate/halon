-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Mero (m0d, HA.Services.Mero.__remoteTableDecl) where

import HA.EventQueue.Producer (expiate, promulgate)
import HA.Resources
import HA.Service
import HA.Services.Empty
import qualified Mero.Notification
import Control.Distributed.Process.Closure
  (
    remotableDecl
  , mkStatic
  , mkStaticClosure
  )
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

remotableDecl [ [d|

    m0d :: Service EmptyConf
    m0d = Service
            (ServiceName "m0d")
            $(mkStaticClosure 'm0dProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictEmptyConf))

    m0dProcess :: EmptyConf -> Process ()
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
            node <- getSelfNode
            let dummyFile = "dummy-striping-error"
            liftIO $ threadDelay 1000000
            exists <- liftIO $ doesFileExist dummyFile
            when exists $ do
              liftIO $ removeFile dummyFile
              void $ promulgate (StripingError (Node node))

        m0ctlMonitor srv out h_m0ctl = loop [] where
          loop buf = do
            let cleanup = do
                    unless (null buf) $ usend srv (reverse buf)
                    usend srv ()
            exited <- liftIO $ getProcessExitCode h_m0ctl
            case exited of
              Just _ -> cleanup
              _ -> do line <- liftIO (hGetLine out) `onException` cleanup
                      case (head line=='-', null buf) of
                        (True,False) -> usend srv (reverse buf) >> loop []
                        (True,True) -> loop []
                        (_,_) -> loop (line:buf)

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
