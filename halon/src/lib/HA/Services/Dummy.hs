-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Should import qualified.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}

module HA.Services.Dummy
  ( dummy
  , DummyConf(..)
  , DummyEvent(..)
  -- * D-P specific functions
  , HA.Services.Dummy.__remoteTable
  , HA.Services.Dummy.__remoteTableDecl
  , dummy__static
  , dummyProcess__tdict
  , dummyProcess__sdict
  ) where

import HA.Service
import HA.Service.TH

#if ! MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )

import Data.Aeson
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

instance ToJSON DummyConf where
  toJSON (DummyConf h) = object [ "hello_string" .= fromDefault h ]

dummySchema :: Schema DummyConf
dummySchema = let
    hw = defaultable "Hello World!" . strOption $ long "helloWorld"
                <> short 'm'
                <> metavar "GREETING"
  in DummyConf <$> hw

$(generateDicts ''DummyConf)
$(deriveService ''DummyConf 'dummySchema [])

-- | An event which produces no action in the RC. Used for testing.
data DummyEvent = DummyEvent String
  deriving (Typeable, Generic)

instance Binary DummyEvent

-- | Block forever.
never :: Process ()
never = receiveWait []

remotableDecl [ [d|
  dummy :: Service DummyConf
  dummy = Service "dummy"
            $(mkStaticClosure 'dummyProcess)
            ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictDummyConf))

  dummyProcess :: DummyConf -> Process ()
  dummyProcess (DummyConf hw) = do
      say $ "Starting service dummy"
      say . fromDefault $ hw
      never

  |] ]
