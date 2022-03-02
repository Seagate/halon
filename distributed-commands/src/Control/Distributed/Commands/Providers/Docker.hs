-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- 'Provider' interface for docker
--

module Control.Distributed.Commands.Providers.Docker
  ( Credentials(..)
  , NewContainerArgs(..)
  , createDefaultProvider
  , createProvider
  ) where

import Prelude hiding ( (<$>) )
import Control.Applicative ( (<$>) )

import Control.Distributed.Commands.Management
  ( Host(..)
  , Provider(..)
  )

import Control.Distributed.Commands.Docker
  ( ContainerData(..)
  , NewContainerArgs(..)
  , Credentials(..)
  , getCredentialsFromEnv
  , newContainer
  , destroyContainer
  )

import Data.Maybe (fromMaybe)

-- | Creates a Provider interface for docker.
--
-- The environment variable DOCKER_HOST needs
-- to be defined.
--
createProvider :: NewContainerArgs -> IO Provider
createProvider args = do
    credentials <- (fromMaybe $ error "DOCKER_HOST not specified in the environment") <$> getCredentialsFromEnv
    return $ Provider $ do
      container <- newContainer credentials args
      return Host
        { destroy    = destroyContainer credentials (containerId container)
        , shutdown   = error "host shutdown is unimplemented"
        , powerOff   = error "host poweroff is unimplemented"
        , powerOn    = error "host poweron is unimplemented"
        , hostNameOf = containerIP container
        }

createDefaultProvider :: IO Provider
createDefaultProvider = createProvider $ NewContainerArgs { image_id = "tweagremote" }
