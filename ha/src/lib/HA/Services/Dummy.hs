-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Dummy
    ( dummy
    , HA.Services.Dummy.__remoteTableDecl ) where

import HA.Resources
import HA.NodeAgent

import Control.Distributed.Process
import Control.Distributed.Process.Closure

import Control.Concurrent (newEmptyMVar, takeMVar)

-- | Block forever.
never :: Process ()
never = liftIO $ newEmptyMVar >>= takeMVar

remotableDecl [ [d|
    dummy :: Service
    dummy = service "dummy" $(mkStaticClosure 'dummyProcess)

    dummyProcess :: Process ()
    dummyProcess = (`catchExit` onExit) $ do
        say $ "Starting service dummy"
        never
      where
        onExit _ Shutdown = say $ "DummyService stopped."

    |] ]
