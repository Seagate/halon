-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- 'Provider' interface for Digital Ocean
--
module Control.Distributed.Commands.Providers.DigitalOcean
  ( Credentials(..)
  , NewDropletArgs(..)
  , createProvider
  , createDefaultProvider
  ) where

import Control.Applicative ( (<$>) )

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
      droplet <- newDroplet credentials args
      return Host
        { destroy    = destroyDroplet credentials (dropletDataId droplet)
        , shutdown   = error "host shutdown is unimplemented"
        , powerOff   = error "host poweroff is unimplemented"
        , powerOn    = error "host poweron is unimplemented"
        , hostNameOf = dropletDataIP droplet
        }

createDefaultProvider :: IO Provider
createDefaultProvider = createProvider $
 NewDropletArgs
      { name        = "test-droplet"
      , size_slug   = "512mb"
      , -- The image is provisioned with halon from an ubuntu system. It has a
        -- user dev with halon built in its home folder. The image also has
        -- /etc/ssh/ssh_config tweaked so copying files from remote to remote
        -- machine does not store hosts in known_hosts.
        image_id    = "7055005"
      , region_slug = "ams2"
      , ssh_key_ids = ""
      }
