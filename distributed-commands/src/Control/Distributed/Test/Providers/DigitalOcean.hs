-- | 'CloudProvider' interface for Digital Ocean
module Control.Distributed.Test.Providers.DigitalOcean
  ( withDigitalOceanDo
  , Credentials(..)
  , NewDropletArgs(..)
  , createCloudProvider
  ) where

import Control.Distributed.Test (Machine(..), IP(..), CloudProvider(..))
import Control.Distributed.Commands.DigitalOcean
  ( withDigitalOceanDo
  , DropletData(..)
  , NewDropletArgs(..)
  , Credentials(..)
  , newDroplet
  , destroyDroplet
  )


-- | Creates a CloudProvider interface for Digital Ocean.
--
-- Before creating any machines @withDigitalOceanDo@ needs to be used.
--
-- The environment variables DO_CLIENT_ID, DO_API_KEY and DO_SSH_KEY_IDS need
-- to be defined.
--
createCloudProvider :: Credentials -> IO NewDropletArgs -> IO CloudProvider
createCloudProvider credentials ioArgs = do
    return $ CloudProvider $ do
      args <- ioArgs
      droplet <- newDroplet credentials args
      return Machine
        { destroy  = destroyDroplet credentials (dropletDataId droplet)
        , shutdown = error "machine shutdown is unimplemented"
        , powerOff = error "machine poweroff is unimplemented"
        , powerOn  = error "machine poweron is unimplemented"
        , ipOf     = IP $ dropletDataIP droplet
        }
