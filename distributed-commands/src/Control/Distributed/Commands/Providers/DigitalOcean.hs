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
  ) where

import Control.Distributed.Commands.Management
  ( Host(..)
  , Provider(..)
  )
import Control.Distributed.Commands.DigitalOcean
  ( DropletData(..)
  , NewDropletArgs(..)
  , Credentials(..)
  , newDroplet
  , destroyDroplet
  )


-- | Creates a CloudProvider interface for Digital Ocean.
--
-- Before creating any hosts @withDigitalOceanDo@ needs to be used.
--
-- The environment variables DO_CLIENT_ID, DO_API_KEY and DO_SSH_KEY_IDS need
-- to be defined.
--
createProvider :: Credentials -> IO NewDropletArgs -> IO Provider
createProvider credentials ioArgs = do
    return $ Provider $ do
      args <- ioArgs
      droplet <- newDroplet credentials args
      return Host
        { destroy    = destroyDroplet credentials (dropletDataId droplet)
        , shutdown   = error "host shutdown is unimplemented"
        , powerOff   = error "host poweroff is unimplemented"
        , powerOn    = error "host poweron is unimplemented"
        , hostNameOf = dropletDataIP droplet
        }
