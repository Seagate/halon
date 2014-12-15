-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Provider management
--
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Control.Distributed.Commands.Providers
  ( getProvider
  ) where

import qualified Control.Distributed.Commands.Management as M
import qualified Control.Distributed.Commands.Providers.DigitalOcean as PDO
import qualified Control.Distributed.Commands.Providers.Docker as PDK

import System.Environment (lookupEnv)

-- | returns the provider chosen by the DC_PROVIDER
--   environment variable

getProvider :: IO M.Provider
getProvider = do
    pname <- lookupEnv "DC_PROVIDER"
    case pname of
      Just "digital-ocean" -> PDO.createDefaultProvider
      Just "docker" -> PDK.createDefaultProvider
      _ -> error "DC_PROVIDER environment variable must specify either digital-ocean or docker"
