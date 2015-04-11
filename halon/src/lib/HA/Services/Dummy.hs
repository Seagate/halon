-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.Dummy
  ( dummy
  , DummyConf(..)
  , HA.Services.Dummy.__remoteTable
  , HA.Services.Dummy.__remoteTableDecl
  ) where

import HA.NodeAgent.Messages
import HA.Service
import HA.Service.TH

#if ! MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Concurrent (newEmptyMVar, takeMVar)

import Data.Binary (Binary)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

newtype DummyConf = DummyConf {
  helloWorld :: Defaultable String
} deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

dummySchema :: Schema DummyConf
dummySchema = let
    hw = defaultable "Hello World!" . strOption $ long "helloWorld"
                <> short 'm'
                <> metavar "GREETING"
  in DummyConf <$> hw

$(generateDicts ''DummyConf)
$(deriveService ''DummyConf 'dummySchema [])

-- | Block forever.
never :: Process ()
never = liftIO $ newEmptyMVar >>= takeMVar

remotableDecl [ [d|
  dummy :: Service DummyConf
  dummy = Service
            (ServiceName "dummy")
            $(mkStaticClosure 'dummyProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictDummyConf))

  dummyProcess :: DummyConf -> Process ()
  dummyProcess (DummyConf hw) = (`catchExit` onExit) $ do
      say $ "Starting service dummy"
      say . fromDefault $ hw
      never
    where
      onExit _ Shutdown = say $ "DummyService stopped."
      onExit _ Reconfigure = say $ "DummyService reconfigured."

  |] ]
