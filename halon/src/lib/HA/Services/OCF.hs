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

import HA.Service
import HA.Resources
import HA.NodeAgent

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

    ocf :: FilePath -> Service ()
    ocf script = service
                  emptySDict
                  ($(mkStatic 'someConfigDict)
                    `staticApply` $(mkStatic 'emptyConfigDict))
                  $(mkStatic 'emptySDict)
                  script $
                  $(mkClosure 'ocfProcess) script

    -- | Pacemaker / RH Cluster Suite SysV init-like service script.
    ocfProcess :: FilePath -> () -> Process ()
    ocfProcess script () = do
        mbpid <- whereis (serviceName nodeAgent)
        let na = maybe (error "NodeAgent is not registered.") id mbpid
        checkExitCode (liftIO $ System.rawSystem script ["start"])
                      go
                      (expire . encodeP $ ServiceCouldNotStart (Node na) $ ocf script)
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
