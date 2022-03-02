-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Provider management
--
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Control.Distributed.Commands.Providers
  ( getProvider
  , getHostAddress
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

-- | Returns host address by the DC_HOST_IP environment variable
getHostAddress :: IO String
getHostAddress = do
    hip <- lookupEnv "DC_HOST_IP"
    case hip of
      Just ip -> return ip
      _       -> fail "DC_HOST_IP environment variable must specify an IP address"
