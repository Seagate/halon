-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- 'Provider' interface for Digital Ocean
--
module Control.Distributed.Commands.Providers.DigitalOcean
  ( Credentials(..)
  , NewDropletArgs(..)
  , createProvider
  , createDefaultProvider
  ) where

import Prelude hiding ( (<$>) )
import Control.Applicative ( (<$>) )

import Control.Distributed.Commands.Internal.Log (debugLog)

import Control.Distributed.Commands.Management
  ( Host(..)
  , Provider(..)
  )
import Control.Distributed.Commands.DigitalOcean
  ( DropletData(..)
  , NewDropletArgs(..)
  , Credentials(..)
  , getCredentialsFromEnv
  , newDroplet
  , destroyDroplet
  )

import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)


-- | Creates a Provider interface for Digital Ocean.
--
-- The environment variables DO_CLIENT_ID, DO_API_KEY and DO_SSH_KEY_IDS need
-- to be defined.
--
createProvider :: NewDropletArgs -> IO Provider
createProvider args = do
    credentials <- (fromMaybe
                    (error "Digital Ocean credentials not specified in the environment")
                   ) <$> getCredentialsFromEnv

    return $ Provider $ do
      debugLog "Creating droplet"
      droplet <- newDroplet credentials args
      debugLog $ "Droplet created with IP " ++ (show $ dropletDataIP droplet)
      return Host
        { destroy    = destroyDroplet credentials (dropletDataId droplet)
        , shutdown   = error "host shutdown is unimplemented"
        , powerOff   = error "host poweroff is unimplemented"
        , powerOn    = error "host poweron is unimplemented"
        , hostNameOf = dropletDataIP droplet
        }

createDefaultProvider :: IO Provider
createDefaultProvider = do
  mimg <- lookupEnv "DC_DO_IMAGEID"
  case mimg of
    Nothing -> error $ "An image Id to create a droplet needs to be provided" ++
                       " in the environment variable DC_DO_IMAGEID."
    Just img -> createProvider $ NewDropletArgs
      { name        = "test-droplet"
      , size_slug   = "512mb"
      , image_id    = img
      , region_slug = "ams2"
      , ssh_key_ids = ""
      }
