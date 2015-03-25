-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.OCF
    ( ocf
    , HA.Services.OCF.__remoteTableDecl ) where

import HA.EventQueue.Producer (expiate)
import HA.NodeAgent.Messages
import HA.Service
import HA.Services.Empty
import HA.Resources

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )

import qualified System.Process as System
import System.Exit (ExitCode(..))
import Control.Concurrent (newEmptyMVar, takeMVar)

-- | Block forever.
never :: Process ()
never = liftIO $ newEmptyMVar >>= takeMVar

remotableDecl [ [d|

    ocf :: FilePath -> Service EmptyConf
    ocf script = Service
                  (ServiceName script)
                  ($(mkClosure 'ocfProcess) script)
                  ($(mkStatic 'someConfigDict)
                    `staticApply` $(mkStatic 'configDictEmptyConf))

    -- | Pacemaker / RH Cluster Suite SysV init-like service script.
    ocfProcess :: FilePath -> EmptyConf -> Process ()
    ocfProcess script _ = do
        node <- getSelfNode
        checkExitCode
          (liftIO $ System.rawSystem script ["start"])
          go
          (expiate . encodeP $ ServiceCouldNotStart (Node node) (ocf script) EmptyConf)
      where
        checkExitCode proc good bad =
          proc >>= \status ->
            case status of
              ExitSuccess -> good
              ExitFailure _ -> bad
        go = catchExit (do never) $ \ _ Shutdown -> do
               checkExitCode (liftIO $ System.rawSystem script ["stop"])
                             (return ())
                             -- XXX send an HA event to the effect of "STONITH please".
                             (return ())

    |] ]
